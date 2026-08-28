import Foundation

/// Produces suggestions by having the local model rewrite the text, then
/// diffing the rewrite against the original.
///
/// This is the part that gives context. Harper matches words against a list and
/// cannot know that `NSString` is a type; the model reads the sentence and
/// leaves it alone. Grammarly runs the same shape: a sequence-to-sequence
/// rewrite for sentence-level context, paired with a mechanism that turns that
/// into individually taggable edits.
///
/// The model is slower than harper by two orders of magnitude, so it does not
/// replace it. Harper marks obvious spelling within milliseconds; this runs
/// afterwards on a longer pause and supersedes those marks once ready.
actor ModelChecker {
    private let rewriter: RewriteEngine
    /// Rewrites already computed, keyed by the exact input text.
    private var cache: [String: String] = [:]
    private var cacheOrder: [String] = []
    private let cacheLimit = 40

    /// Above this the model is too slow to feel live, and its output drifts
    /// further from the input the more it is given.
    let maxLength: Int

    init(rewriter: RewriteEngine, maxLength: Int = 600) {
        self.rewriter = rewriter
        self.maxLength = maxLength
    }

    /// Suggestions for `text`, or an empty array if the model cannot help.
    func check(_ text: String) async -> [Suggestion] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLength else { return [] }

        let corrected: String
        if let hit = cache[trimmed] {
            corrected = hit
        } else {
            guard let result = try? await rewriter.rewrite(trimmed, mode: .fixGrammar),
                  !result.isEmpty
            else { return [] }
            corrected = result
            remember(trimmed, result)
        }

        guard isTrustworthy(original: trimmed, corrected: corrected) else { return [] }
        return WordDiff.suggestions(from: text, to: corrected,
                                    message: "Suggested correction")
    }

    /// Rejects a rewrite that strayed too far to be a correction.
    ///
    /// A small model asked to fix grammar will sometimes answer the text
    /// instead of correcting it, summarise it, or return commentary. Applying
    /// that as a set of inline "corrections" would silently rewrite the user's
    /// meaning, so a rewrite is only trusted if it still resembles the input.
    nonisolated func isTrustworthy(original: String, corrected: String) -> Bool {
        if corrected == original { return true }

        let originalWords = WordDiff.tokenize(original).map { $0.text.lowercased() }
        let correctedWords = WordDiff.tokenize(corrected).map { $0.text.lowercased() }
        guard !originalWords.isEmpty, !correctedWords.isEmpty else { return false }

        // Cheap first pass: a wholesale change in length means it summarised,
        // padded, or answered rather than corrected.
        let wordRatio = Double(correctedWords.count) / Double(originalWords.count)
        guard wordRatio >= 0.6, wordRatio <= 1.6 else { return false }

        // Similarity is measured over CHARACTERS, not whole words. Correcting
        // spelling changes the words themselves -- "Their is many erors" to
        // "There are many errors" keeps only two words out of five intact --
        // so word overlap scores real corrections as if they were rewrites.
        return characterSimilarity(original.lowercased(), corrected.lowercased()) >= 0.5
    }

    /// 1.0 for identical strings, approaching 0 as they diverge.
    nonisolated func characterSimilarity(_ a: String, _ b: String) -> Double {
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 1 }
        let distance = SuggestionFilter.editDistance(a, b)
        return 1 - Double(distance) / Double(longest)
    }

    private func remember(_ input: String, _ output: String) {
        cache[input] = output
        cacheOrder.append(input)
        while cacheOrder.count > cacheLimit {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }
}
