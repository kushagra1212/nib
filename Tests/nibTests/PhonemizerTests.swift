import XCTest
@testable import nib

/// Text to phonemes, checked against the Python engine over 28 texts.
///
/// espeak is not loaded here. The fixture records what espeak returned for each
/// chunk of each text, and those recordings are played back, so what is under
/// test is the part that was ported: hiding punctuation, tidying espeak's
/// output, putting the punctuation back, and dropping what the model does not
/// know.
///
/// That split is deliberate. When speech comes out wrong there are two
/// suspects, and this decides between them: if these tests pass and the app
/// still mispronounces, the espeak binding is at fault, not the assembly.
///
/// The failure being guarded against is a dropped full stop. It is a token in
/// its own right -- id 4 -- and without it a sentence ends flat instead of
/// finishing. Nothing errors; it just sounds worse.
final class PhonemizerTests: XCTestCase {
    private struct Golden: Decodable {
        struct Mark: Decodable {
            let mark: String
            let position: String
        }
        struct Entry: Decodable {
            let name: String
            let text: String
            let preserved_chunks: [String]
            let marks: [Mark]
            let chunk_phonemes: [String]
            let phonemizer: String
            let phonemes: String
        }
        let entries: [Entry]
        let punctuation_marks: String
    }

    private func golden() throws -> Golden {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/phonemes-golden.json")
        return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
    }

    /// Plays back what espeak said for each chunk, in order.
    ///
    /// Keyed by chunk text rather than by call order, so a port that phonemises
    /// the wrong chunks fails on the lookup instead of silently reading the
    /// recording of a different one.
    private struct Recorded: PhonemeSource {
        let answers: [String: String]

        func phonemes(for text: String) throws -> String {
            guard let answer = answers[text] else {
                throw Failure.notRecorded(text)
            }
            return answer
        }

        enum Failure: Error, CustomStringConvertible {
            case notRecorded(String)
            var description: String {
                switch self {
                case .notRecorded(let text):
                    return "espeak was asked for \(text.debugDescription), which "
                        + "is not a chunk the engine produced"
                }
            }
        }
    }

    private func source(_ entry: Golden.Entry) -> Recorded {
        Recorded(answers: Dictionary(
            zip(entry.preserved_chunks, entry.chunk_phonemes),
            uniquingKeysWith: { first, _ in first }))
    }

    // MARK: - The whole path

    /// The comparison that matters. Same text in, same phonemes out as the
    /// engine, for every text in the corpus.
    func testThePhonemesMatchTheEngine() throws {
        for entry in try golden().entries {
            let phonemes = try Phonemizer.phonemes(of: entry.text,
                                                   using: source(entry))
            XCTAssertEqual(phonemes, entry.phonemes,
                           "\(entry.name): \(entry.text.debugDescription)")
        }
    }

    /// Before the vocabulary filter, which is where phonemizer itself stops.
    /// Separated so a divergence says whether it is the assembly or the table.
    func testTheUnfilteredOutputMatchesPhonemizer() throws {
        for entry in try golden().entries {
            let raw = try Phonemizer.phonemize(entry.text, using: source(entry))
            XCTAssertEqual(raw, entry.phonemizer,
                           "\(entry.name): \(entry.text.debugDescription)")
        }
    }

    // MARK: - Hiding the punctuation

    func testTheChunksMatchTheEngine() throws {
        for entry in try golden().entries {
            let (chunks, _) = PhonemePunctuation.preserve(entry.text)
            XCTAssertEqual(chunks, entry.preserved_chunks, "\(entry.name)")
        }
    }

    func testTheMarksAndTheirPositionsMatchTheEngine() throws {
        for entry in try golden().entries {
            let (_, marks) = PhonemePunctuation.preserve(entry.text)
            XCTAssertEqual(marks.map(\.text), entry.marks.map(\.mark),
                           "\(entry.name)")
            XCTAssertEqual(marks.map(\.position.rawValue),
                           entry.marks.map(\.position), "\(entry.name)")
        }
    }

    /// The mark set has to be phonemizer's, exactly. A mark missing from it is
    /// not hidden from espeak, which drops it -- so it never reaches the model.
    func testTheMarkSetIsPhonemizersOwn() throws {
        XCTAssertEqual(PhonemePunctuation.defaultMarks,
                       Set(try golden().punctuation_marks))
    }

    // MARK: - The corpus earns its keep

    /// A corpus of plain sentences would pass every test above while the
    /// interesting paths went unrun.
    func testTheCorpusCoversEveryPosition() throws {
        let positions = Set(try golden().entries.flatMap { $0.marks.map(\.position) })
        for expected in ["B", "E", "I", "A"] {
            XCTAssertTrue(positions.contains(expected),
                          "no text puts a mark in position \(expected)")
        }
    }

    func testTheCorpusCoversTextWithNoMarksAtAll() throws {
        XCTAssertTrue(try golden().entries.contains { $0.marks.isEmpty })
    }

    // MARK: - The rules that are easy to get wrong

    /// A decimal separator between digits is part of the number. Split there
    /// and espeak reads two numbers: "19,99" becomes "nineteen ninety nine".
    func testADecimalSeparatorIsNotPunctuation() {
        let (chunks, marks) = PhonemePunctuation.preserve("It costs 19,99 euro.")
        XCTAssertEqual(chunks, ["It costs 19,99 euro"])
        XCTAssertEqual(marks.map(\.text), ["."])
    }

    /// The same character at the end of a number is ordinary punctuation.
    func testASeparatorNotBetweenDigitsIsPunctuation() {
        let (chunks, _) = PhonemePunctuation.preserve("I have 5, you have 6.")
        XCTAssertEqual(chunks, ["I have 5", "you have 6"])
    }

    /// Whitespace either side of a mark belongs to the mark, and reappears
    /// between the phonemes. Without it the words either side run together.
    func testAMarkCarriesTheSpaceAroundIt() {
        let (_, marks) = PhonemePunctuation.preserve("One. Two. Three.")
        XCTAssertEqual(marks.map(\.text), [". ", ". ", "."])
    }

    /// Whitespace with no mark in it is not a boundary. Treating it as one
    /// would split every sentence at every space.
    func testPlainWhitespaceIsNotAMark() {
        let (chunks, marks) = PhonemePunctuation.preserve("the quick brown fox")
        XCTAssertEqual(chunks, ["the quick brown fox"])
        XCTAssertTrue(marks.isEmpty)
    }

    /// A line of marks alone has nothing to attach to and is returned as it is.
    func testMarksAloneSurviveWithNoPhonemes() throws {
        let (chunks, marks) = PhonemePunctuation.preserve("...")
        XCTAssertTrue(chunks.isEmpty)
        XCTAssertEqual(marks, [PhonemePunctuation.Mark(line: 0, text: "...",
                                                      position: .alone)])

        let restored = PhonemePunctuation.restore([], marks: marks,
                                                  separator: " ", strip: false)
        XCTAssertEqual(restored, ["..."])
    }

    // MARK: - Tidying espeak's output

    /// espeak separates phonemes with underscores. They are a separator, not
    /// sound, and leaving one in puts a symbol the model cannot read into the
    /// sentence -- where it is dropped, taking nothing else with it, so the
    /// only sign is a missing phoneme.
    func testUnderscoresAreRemoved() {
        XCTAssertEqual(Phonemizer.tidy("ð_ə k_w_ˈɪ_k"), "ðə kwˈɪk ")
    }

    /// espeak-ng appends extra separators to some words (issue 694). Runs
    /// collapse rather than each becoming its own gap.
    func testDoubledUnderscoresCollapse() {
        XCTAssertEqual(Phonemizer.tidy("l_ˈaɪ_k ð_ˈɪ_s__"), "lˈaɪk ðˈɪs ")
    }

    /// The trailing separator is left on, because restoration takes it off
    /// again when it puts a mark there. Stripping it here would give "hello ."
    func testTheTrailingSeparatorIsLeftOn() {
        XCTAssertTrue(Phonemizer.tidy("h_ə_l_ˈoʊ").hasSuffix(" "))
        XCTAssertEqual(Phonemizer.tidy("h_ə_l_ˈoʊ", strip: true), "həlˈoʊ")
    }

    func testEmptyEspeakOutputStaysEmpty() {
        XCTAssertEqual(Phonemizer.tidy(""), "")
        XCTAssertEqual(Phonemizer.tidy("   "), "")
    }

    // MARK: - What the vocabulary drops

    /// Round brackets are in the vocabulary and square ones are not, so one
    /// pair survives and the other disappears. Recorded because it looks like
    /// a bug the first time it is seen.
    func testUnknownSymbolsAreDroppedSilently() throws {
        let entry = try XCTUnwrap(golden().entries.first { $0.name == "brackets" })
        let phonemes = try Phonemizer.phonemes(of: entry.text, using: source(entry))
        XCTAssertTrue(phonemes.contains("("), "round brackets are in the vocabulary")
        XCTAssertFalse(phonemes.contains("["), "square brackets are not")
        XCTAssertTrue(phonemes.contains("bɹˈækɪts"), "the word itself must survive")
    }

    /// Every phoneme that comes out must be tokenisable, or it is dropped again
    /// later and a word goes missing with nothing said about it.
    func testEveryPhonemeProducedIsKnownToTheTokeniser() throws {
        for entry in try golden().entries {
            let phonemes = try Phonemizer.phonemes(of: entry.text,
                                                   using: source(entry))
            XCTAssertEqual(KokoroTokenizer.unknown(in: phonemes), [],
                           "\(entry.name) produced a symbol the model cannot read")
        }
    }

    // MARK: - Edges

    func testEmptyTextProducesNoPhonemes() throws {
        let empty = Recorded(answers: [:])
        XCTAssertEqual(try Phonemizer.phonemes(of: "", using: empty), "")
    }

    /// A chunk that was never recorded means the port asked espeak for
    /// something the engine never asked for. That has to fail loudly.
    func testAnUnexpectedChunkIsReported() {
        let empty = Recorded(answers: [:])
        XCTAssertThrowsError(try Phonemizer.phonemize("hello.", using: empty))
    }
}
