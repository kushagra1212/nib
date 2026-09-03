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

    /// Largest model that may run on every typing pause.
    ///
    /// The live pass is not asked for. It fires 0.9s after you stop typing, in
    /// whatever field has focus, and it calls the model twice -- check, then
    /// clarity. With the 805MB 0.6B that is about 0.2s and a server small
    /// enough to forget about. With the 2.5GB 4B it is about 1s of six-thread
    /// work, and because every pass resets the idle timer the 2.7GB server
    /// never gets to exit while someone is typing.
    ///
    /// So the rule is about who asked. Work nobody requested has to stay cheap;
    /// work behind a button may cost what it needs to. Above this size the live
    /// pass is off and Harper alone underlines, which is 30ms and the thing
    /// people actually notice; the big model still answers Fix, Clearer,
    /// Shorter and Native.
    static let liveModelSizeLimit: Int64 = 1_500_000_000

    /// Whether this model is cheap enough to run unbidden.
    static func isLightEnoughForLiveUse(_ modelPath: URL) -> Bool {
        let size = (try? modelPath.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return Int64(size) <= liveModelSizeLimit
    }

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
        guard !flipsQuestion(original: trimmed, corrected: corrected) else { return [] }
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
    nonisolated func dropsContent(
        original: String, corrected: String, limit: Int = 3
    ) -> Bool {
        longestDroppedRun(original: original, corrected: corrected) >= limit
    }

    /// Whether a rewrite turned a question into a statement.
    ///
    /// "The approach you have given, is this safe?" came back as "The approach
    /// you have given is this safe approach." -- the question mark gone and
    /// with it the fact that anything was being asked. Punctuation is the
    /// smallest possible edit and one of the largest possible changes in
    /// meaning, so no similarity or deletion check notices it: one character
    /// out of fifty.
    ///
    /// Only in that direction. Adding a question mark to something that reads
    /// as a question is a real correction.
    nonisolated func flipsQuestion(original: String, corrected: String) -> Bool {
        let asked = original.trimmingCharacters(in: .whitespacesAndNewlines)
            .hasSuffix("?")
        let answers = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
            .hasSuffix("?")
        return asked && !answers
    }

    /// How many words were dropped from the very end.
    ///
    /// The distinction the run count cannot make. "we should probably think
    /// about maybe adding a check" losing "probably think about maybe" is a
    /// rewrite doing its job -- four words, mid-sentence, all filler. The same
    /// four words missing off the end is a truncated sentence, and that is the
    /// failure this was written for: a Slack message that lost "product
    /// details 3 options" and said nothing about it.
    ///
    /// Middle deletions are a matter of taste and belong to the mode. A
    /// truncated ending is wrong in every mode.
    nonisolated func droppedTail(original: String, corrected: String) -> Int {
        let before = WordDiff.tokenize(original).map { $0.text.lowercased() }
        let after = WordDiff.tokenize(corrected).map { $0.text.lowercased() }
        guard !before.isEmpty else { return 0 }
        let kept = WordDiff.longestCommonSubsequence(before, after)
        guard let last = kept.last else { return before.count }
        guard let index = before.lastIndex(of: last) else { return before.count }
        return before.count - 1 - index
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
            // Each guard below is a different reason to say nothing, and from
            // outside they all look the same: hovering a clean line and
            // getting no rewrite. The log says which one fired.
            let short = sentence.text.prefix(32)
            guard let rewritten = await rewrite(sentence.text, mode: .clearer) else {
                Log.write("clarity \"\(short)\": model gave nothing")
                continue
            }
            guard rewritten != sentence.text else {
                Log.write("clarity \"\(short)\": unchanged")
                continue
            }
            let similarity = characterSimilarity(sentence.text.lowercased(),
                                                 rewritten.lowercased())
            let dropped = longestDroppedRun(original: sentence.text,
                                            corrected: rewritten)
            Log.write("clarity \"\(short)\": similarity "
                      + String(format: "%.2f", similarity) + ", dropped run \(dropped)")
            // A clarity rewrite may restructure, so the tighter inline gate
            // does not apply; it only has to remain about the same sentence.
            guard characterSimilarity(sentence.text.lowercased(),
                                      rewritten.lowercased()) >= 0.35 else { continue }
            // Ignore changes too small to be worth interrupting for.
            guard characterSimilarity(sentence.text.lowercased(),
                                      rewritten.lowercased()) <= 0.97 else { continue }
            // Restructuring is allowed here. Deleting is not: "clearer" that
            // loses the end of the sentence is not clearer.
            // Tightening a sentence is what clarity is for, so a run of
            // dropped words in the middle is allowed here. Losing the end is
            // not: that is a truncation whatever it is called.
            guard droppedTail(original: sentence.text, corrected: rewritten) < 3
            else {
                Log.write("clarity \"\(short)\": truncated the ending")
                continue
            }
            guard !flipsQuestion(original: sentence.text,
                                 corrected: rewritten) else {
                Log.write("clarity \"\(short)\": turned a question into a statement")
                continue
            }

            out.append(Suggestion(kind: .clarity, source: .model,
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
    /// The longest run of the original a rewrite may drop before it is refused.
    ///
    /// Three words. This used to come off the strength dial, where the boldest
    /// setting turned it off entirely -- so removing the dial would have
    /// disabled it for good. The dial asked how far a rewrite may travel; this
    /// asks whether it quietly deleted a clause, which is a different question
    /// and is wrong at any setting.
    static let maxDroppedRun = 3

    func rewriteSelection(
        _ text: String, mode: RewriteMode
    ) async throws -> RewriteOutcome {
        let key = "\(mode.rawValue)|\(text)"
        if let hit = cache[key] {
            return hit == text ? .unchanged : .rewritten(hit)
        }
        let result = try await rewriter.rewrite(text, mode: mode)

        // Native and Shorter are asked to move or drop words by definition.
        // A sentence that stops early is wrong in every mode, however freely
        // it was asked to rewrite: the end of what someone wrote is missing
        // and nothing says so.
        if droppedTail(original: text, corrected: result) >= 3 {
            Log.write("rewrite truncated the ending, mode=\(mode.rawValue)")
            return .refused("that rewrite cut off the ending")
        }

        // A question that comes back as a statement is wrong in every mode,
        // however freely it was asked to rewrite.
        if flipsQuestion(original: text, corrected: result) {
            Log.write("rewrite turned a question into a statement, mode=\(mode.rawValue)")
            return .refused("that rewrite answered your question instead of "
                            + "rewriting it")
        }

        if !mode.mayRestructure,
           dropsContent(original: text, corrected: result,
                        limit: Self.maxDroppedRun) {
            Log.write("rewrite dropped content, mode=\(mode.rawValue) "
                      + "run=\(longestDroppedRun(original: text, corrected: result))")
            return .refused("that rewrite dropped part of what you wrote")
        }
        remember(key, result)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
            == text.trimmingCharacters(in: .whitespacesAndNewlines)
            ? .unchanged : .rewritten(result)
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
