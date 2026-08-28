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
        guard !dropsContent(original: trimmed, corrected: corrected) else { return [] }
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

    /// Whether a rewrite quietly deleted a stretch of what was written.
    ///
    /// Asked to tidy "...to see the product that they click on product details
    /// 3 options", the model returned "...to see the product that they click
    /// on." -- four words gone from the end. Every existing gate passed it: the
    /// word count barely moved, and dropping four words out of thirty-three
    /// leaves the characters almost identical. Both gates measure how alike the
    /// two strings are, and neither asks whether the writing survived.
    ///
    /// A run rather than a total, because scattered single misses are what a
    /// real correction looks like -- "their is many erors" changes three of
    /// five words. Three in a row is a deletion.
    nonisolated func dropsContent(original: String, corrected: String) -> Bool {
        longestDroppedRun(original: original, corrected: corrected) >= 3
    }

    /// The longest stretch of consecutive words present in the original and
    /// missing from the rewrite.
    nonisolated func longestDroppedRun(original: String, corrected: String) -> Int {
        let before = WordDiff.tokenize(original).map { $0.text.lowercased() }
        let after = WordDiff.tokenize(corrected).map { $0.text.lowercased() }
        guard !before.isEmpty else { return 0 }

        // The subsequence is what survived, in order, so walking the original
        // against it marks every word the rewrite did not keep.
        let kept = WordDiff.longestCommonSubsequence(before, after)
        var index = 0
        var run = 0
        var longest = 0
        for word in before {
            if index < kept.count, word == kept[index] {
                index += 1
                run = 0
            } else {
                run += 1
                longest = max(longest, run)
            }
        }
        return longest
    }

    /// 1.0 for identical strings, approaching 0 as they diverge.
    nonisolated func characterSimilarity(_ a: String, _ b: String) -> Double {
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 1 }
        let distance = SuggestionFilter.editDistance(a, b)
        return 1 - Double(distance) / Double(longest)
    }

    /// Clarity suggestions: one per sentence that could read better.
    ///
    /// Separate from `check` because it asks a different question and produces
    /// a different kind of mark. A sentence is rewritten as a whole, so the
    /// suggestion covers the whole sentence rather than a word.
    func clarity(_ text: String, limit: Int = 4) async -> [Suggestion] {
        let sentences = SentenceSplitter.sentences(in: text)
        guard !sentences.isEmpty else { return [] }

        var out: [Suggestion] = []
        for sentence in sentences.prefix(limit) {
            guard let rewritten = await rewrite(sentence.text, mode: .clearer) else { continue }
            guard rewritten != sentence.text else { continue }
            // A clarity rewrite may restructure, so the tighter inline gate
            // does not apply; it only has to remain about the same sentence.
            guard characterSimilarity(sentence.text.lowercased(),
                                      rewritten.lowercased()) >= 0.35 else { continue }
            // Ignore changes too small to be worth interrupting for.
            guard characterSimilarity(sentence.text.lowercased(),
                                      rewritten.lowercased()) <= 0.97 else { continue }
            // Restructuring is allowed here. Deleting is not: "clearer" that
            // loses the end of the sentence is not clearer.
            guard !dropsContent(original: sentence.text,
                                corrected: rewritten) else { continue }

            out.append(Suggestion(kind: .clarity,
                                  range: sentence.range,
                                  message: "This could read more clearly",
                                  replacements: [rewritten]))
        }
        return out
    }

    /// Rewrites a selection the user explicitly asked about.
    ///
    /// The similarity gates do not apply: the user picked the text and the
    /// mode, sees the result before it is applied, and asking for "shorter"
    /// legitimately produces something that shares little with the original.
    ///
    /// Deletion is different. "Shorter" is licensed to drop words; "fix" and
    /// "clearer" are not, and a rewrite that quietly loses the end of a
    /// sentence is easy to accept without noticing. When that happens the
    /// original comes back unchanged, which reads as "nothing to do" rather
    /// than handing over a shortened version of what was written.
    func rewriteSelection(_ text: String, mode: RewriteMode) async throws -> String {
        if let hit = cache["\(mode.rawValue)|\(text)"] { return hit }
        let result = try await rewriter.rewrite(text, mode: mode)

        if mode != .shorter, dropsContent(original: text, corrected: result) {
            Log.write("rewrite dropped content, mode=\(mode.rawValue) "
                      + "run=\(longestDroppedRun(original: text, corrected: result))")
            return text
        }
        remember("\(mode.rawValue)|\(text)", result)
        return result
    }

    private func rewrite(_ text: String, mode: RewriteMode) async -> String? {
        let key = "\(mode.rawValue)|\(text)"
        if let hit = cache[key] { return hit }
        guard let result = try? await rewriter.rewrite(text, mode: mode),
              !result.isEmpty else { return nil }
        remember(key, result)
        return result
    }

    private func remember(_ input: String, _ output: String) {
        cache[input] = output
        cacheOrder.append(input)
        while cacheOrder.count > cacheLimit {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }
}
