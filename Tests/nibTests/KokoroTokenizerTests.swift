import XCTest
@testable import nib

/// The phoneme table and the rule that uses it, checked against the engine.
///
/// This is the test the speech port was designed around. Getting a token id
/// wrong does not fail: the model speaks a different sound, confidently, and
/// the output is fluent English that is not what was written. There is no
/// error to notice and no line to blame, so it has to be caught by comparison
/// with the engine that is known to work.
///
/// The fixture in Tests/Fixtures/kokoro-golden.json was produced by the Python
/// engine on this machine: one sentence, its phonemes, the ids it produced, and
/// a hash of the audio that came out.
final class KokoroTokenizerTests: XCTestCase {
    private struct Golden: Decodable {
        let text: String
        let voice: String
        let speed: Double
        let lang: String
        let phonemes: String
        let token_ids: [Int]
        let sample_rate: Int
        let sample_count: Int
        let sha256_float32_le: String
    }

    private func golden() throws -> Golden {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // nibTests
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("Fixtures/kokoro-golden.json")
        return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
    }

    // MARK: - The comparison that matters

    /// The whole point. Feed the phonemes the Python engine produced through
    /// this table and expect the ids it produced, exactly.
    func testTheTableAgreesWithTheEngine() throws {
        let reference = try golden()
        let ids = try KokoroTokenizer.tokenize(reference.phonemes)
        XCTAssertEqual(ids, reference.token_ids,
                       "a differing id means a different sound, spoken fluently")
    }

    /// A count check on its own would pass while every id was wrong, so this
    /// exists to make the failure above readable rather than to add coverage.
    func testTheCountMatchesToo() throws {
        let reference = try golden()
        XCTAssertEqual(try KokoroTokenizer.tokenize(reference.phonemes).count,
                       reference.token_ids.count)
    }

    /// Every symbol in a real transcript must be in the table. One that is not
    /// gets silently dropped, which shortens the sentence rather than breaking
    /// it -- a word disappears and nothing reports it.
    func testTheEnginesOwnPhonemesAreAllKnown() throws {
        let reference = try golden()
        XCTAssertEqual(KokoroTokenizer.unknown(in: reference.phonemes), [],
                       "an unknown symbol is dropped, so a word goes missing")
    }

    // MARK: - The table itself

    func testTheTableCameFromTheEngine() {
        XCTAssertEqual(KokoroVocab.table.count, 114)
        XCTAssertEqual(KokoroVocab.table.values.max(), 177)
        XCTAssertFalse(KokoroVocab.sourceDigest.isEmpty)
    }

    /// Two symbols sharing an id would make one of them unpronounceable.
    func testEveryIdIsUsedOnce() {
        let ids = Array(KokoroVocab.table.values)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    /// Zero is the padding value in this family of models; a real phoneme
    /// mapped to it would be read as "nothing here".
    func testNothingMapsToZero() {
        XCTAssertFalse(KokoroVocab.table.values.contains(0))
    }

    /// Multi-byte symbols must survive as whole symbols. Splitting "ð" any
    /// other way yields ids for fragments, which is the subtle-wrong-sound
    /// failure in its purest form.
    func testMultiByteSymbolsAreWholeSymbols() {
        for symbol in ["ð", "ɹ", "ˈ", "ɑ", "ʊ"] {
            XCTAssertNotNil(KokoroVocab.table[symbol],
                            "\(symbol) is in the engine's transcript and must map")
        }
    }

    // MARK: - Edges

    func testEmptyInputProducesNoTokens() throws {
        XCTAssertEqual(try KokoroTokenizer.tokenize(""), [])
    }

    /// Refused rather than truncated. Python raises here, and quietly cutting
    /// a sentence in half would be worse than saying it is too long.
    func testOverlongInputIsRefused() {
        let tooMany = String(repeating: "ð", count: KokoroVocab.maxPhonemes + 1)
        XCTAssertThrowsError(try KokoroTokenizer.tokenize(tooMany))
    }

    func testExactlyTheLimitIsAllowed() {
        let atLimit = String(repeating: "ð", count: KokoroVocab.maxPhonemes)
        XCTAssertNoThrow(try KokoroTokenizer.tokenize(atLimit))
    }

    /// Unknown symbols are dropped, matching Python, rather than throwing or
    /// substituting a placeholder.
    func testUnknownSymbolsAreDroppedNotSubstituted() throws {
        let ids = try KokoroTokenizer.tokenize("ð\u{1F600}ə")
        let clean = try KokoroTokenizer.tokenize("ðə")
        XCTAssertEqual(ids, clean)
    }
}
