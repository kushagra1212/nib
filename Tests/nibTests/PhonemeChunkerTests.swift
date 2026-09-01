import XCTest
@testable import nib

/// Splitting long text into batches, checked against the Python chunker.
///
/// Runs everywhere: the fixture already holds what the engine produced, so
/// nothing here needs espeak or the model. Every entry in
/// `Tests/Fixtures/phonemes-golden.json` carries the batches kokoro made from
/// its phonemes, and this feeds the same phonemes in and expects the same
/// batches out.
///
/// The failure being guarded against is not a crash. Batching in the wrong
/// place is audible as a stutter mid-word, or as a paragraph whose last few
/// words are spoken faster than the rest -- both of which sound like a poor
/// model rather than a bug in a splitter.
final class PhonemeChunkerTests: XCTestCase {
    private struct Golden: Decodable {
        struct Batch: Decodable {
            let phonemes: String
            let token_ids: [Int]
            let pause_after: Double
        }
        struct Entry: Decodable {
            let name: String
            let text: String
            let phonemes: String
            let batches: [Batch]
            let token_count: Int
        }
        let entries: [Entry]
    }

    private func golden() throws -> Golden {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/phonemes-golden.json")
        return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
    }

    // MARK: - Against the engine

    /// Every text in the corpus, split the way kokoro split it.
    func testTheBatchesMatchTheEngine() throws {
        for entry in try golden().entries {
            let batches = PhonemeChunker.split(entry.phonemes)
            XCTAssertEqual(batches, entry.batches.map(\.phonemes),
                           "\(entry.name): \(entry.text.prefix(40))")
        }
    }

    /// The corpus has to contain a text that actually splits, or the test above
    /// passes by only ever seeing one batch.
    func testTheCorpusExercisesSplitting() throws {
        let entries = try golden().entries
        XCTAssertTrue(entries.contains { $0.batches.count > 1 },
                      "no entry is long enough to split; the corpus proves nothing")
        XCTAssertTrue(entries.contains { $0.token_count > KokoroVocab.maxPhonemes },
                      "no entry exceeds the model's context")
    }

    /// The pause after each batch, which is what puts a full stop back after
    /// trimming has removed the silence the model left there.
    func testThePausesMatchTheEngine() throws {
        for entry in try golden().entries {
            for batch in entry.batches {
                XCTAssertEqual(
                    PhonemeChunker.pause(after: batch.phonemes,
                                         sentence: 0.25, clause: 0.1),
                    batch.pause_after, accuracy: 1e-9,
                    "\(entry.name): \(batch.phonemes.suffix(20))")
            }
        }
    }

    /// No batch may exceed the context, whatever the input. A batch that does
    /// is refused by the tokeniser at synthesis time, mid-sentence.
    func testNoBatchExceedsTheContext() throws {
        for entry in try golden().entries {
            for batch in PhonemeChunker.split(entry.phonemes) {
                XCTAssertLessThanOrEqual(batch.count, KokoroVocab.maxPhonemes,
                                         "\(entry.name)")
            }
        }
    }

    /// Nothing may be dropped. Losing a phoneme is silent -- a word simply is
    /// not spoken -- so the batches are compared against the input word by word.
    func testNothingIsLost() throws {
        for entry in try golden().entries {
            let rejoined = PhonemeChunker.split(entry.phonemes)
                .joined(separator: " ")
            XCTAssertEqual(rejoined.split(separator: " "),
                           entry.phonemes.split(separator: " "),
                           "\(entry.name) lost or gained a word")
        }
    }

    // MARK: - Where it cuts

    /// A sentence boundary is preferred over a word boundary, and the full stop
    /// stays with the sentence it ends.
    func testItCutsAtSentencesFirst() {
        let sentence = String(repeating: "a", count: 200)
        let text = "\(sentence). \(sentence). \(sentence)."
        for batch in PhonemeChunker.split(text, limit: 500) {
            XCTAssertTrue(batch.hasSuffix("."), "cut away from a sentence end: \(batch.prefix(12))…")
        }
    }

    /// Then clauses, when there is no sentence mark to use.
    func testItCutsAtClausesNext() {
        let clause = String(repeating: "a", count: 200)
        let batches = PhonemeChunker.split("\(clause), \(clause), \(clause)", limit: 500)
        XCTAssertTrue(batches.count > 1)
        for batch in batches.dropLast() {
            XCTAssertTrue(batch.hasSuffix(","), "\(batch.prefix(12))…")
        }
    }

    /// Then words. A word is never cut while a space is available.
    func testItCutsAtWordsLast() {
        let word = String(repeating: "a", count: 200)
        let batches = PhonemeChunker.split("\(word) \(word) \(word)", limit: 500)
        XCTAssertTrue(batches.count > 1)
        for batch in batches {
            XCTAssertFalse(batch.hasPrefix(" ") || batch.hasSuffix(" "))
        }
    }

    /// One unbroken run longer than the context is sliced rather than dropped.
    /// Returning nothing here would lose the text with no error.
    func testOneLongWordIsSlicedNotDropped() {
        let run = String(repeating: "a", count: 1200)
        let batches = PhonemeChunker.split(run, limit: 500)
        XCTAssertEqual(batches.joined(), run)
        XCTAssertEqual(batches.count, 3)
    }

    // MARK: - Balance

    /// The reason for the binary search. Filling to the limit would leave a
    /// short last batch, spoken faster and quieter than the ones before it.
    func testBatchesAreBalancedRatherThanFilled() {
        let word = String(repeating: "a", count: 90)
        let text = Array(repeating: word, count: 11).joined(separator: " ")

        let batches = PhonemeChunker.split(text, limit: 500)
        let sizes = batches.map(\.count)
        XCTAssertEqual(batches.count, 3)
        // Filling greedily would give 5 words, 5 words, 1 word -- a final
        // batch a fifth the length of the others.
        XCTAssertLessThanOrEqual((sizes.max() ?? 0) - (sizes.min() ?? 0), 100,
                                 "sizes \(sizes) are lopsided")
    }

    // MARK: - Edges

    func testEmptyTextProducesNoBatches() {
        XCTAssertEqual(PhonemeChunker.split(""), [])
        XCTAssertEqual(PhonemeChunker.split("   "), [])
    }

    func testShortTextIsOneBatch() {
        XCTAssertEqual(PhonemeChunker.split("ðə kwˈɪk"), ["ðə kwˈɪk"])
    }

    /// Multiple spaces are one boundary, not several empty pieces between them.
    func testRunsOfWhitespaceAreOneBoundary() {
        let word = String(repeating: "a", count: 300)
        XCTAssertEqual(PhonemeChunker.split("\(word)   \(word)", limit: 400),
                       [word, word])
    }

    func testTextWithoutMarksStillSplitsAtWords() {
        let word = String(repeating: "a", count: 300)
        XCTAssertEqual(PhonemeChunker.split("\(word) \(word)", limit: 400).count, 2)
    }

    // MARK: - Pauses

    func testASentenceMarkPausesLongerThanAClause() {
        XCTAssertEqual(PhonemeChunker.pause(after: "hˈɛloʊ.", sentence: 0.25, clause: 0.1), 0.25)
        XCTAssertEqual(PhonemeChunker.pause(after: "hˈɛloʊ,", sentence: 0.25, clause: 0.1), 0.1)
        XCTAssertEqual(PhonemeChunker.pause(after: "hˈɛloʊ", sentence: 0.25, clause: 0.1), 0)
    }

    /// Trailing space must not hide the mark; the batch would then run into the
    /// next one with no gap.
    func testTrailingSpaceDoesNotHideTheMark() {
        XCTAssertEqual(PhonemeChunker.pause(after: "hˈɛloʊ.  ", sentence: 0.25, clause: 0.1), 0.25)
    }

    func testAnEmptyBatchHasNoPause() {
        XCTAssertEqual(PhonemeChunker.pause(after: "", sentence: 0.25, clause: 0.1), 0)
    }
}
