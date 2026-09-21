import XCTest
@testable import nib

/// The word list that fixes what accents do not.
///
/// Measured on Indian-accented speech with the small model: ordinary sentences
/// were already correct, and every failure was a name the model had never seen
/// -- "useMemo" as "Usamimohuk", "Hasura" as "Azure". Priming fixed both
/// exactly. This covers the plumbing that carries it.
final class SpeechVocabularyTests: XCTestCase {
    // MARK: - The prompt

    func testThePromptReadsAsProseNotAList() {
        let prompt = SpeechVocabulary.prompt(["Hasura", "useMemo"])
        XCTAssertEqual(prompt, "Terms used: Hasura, useMemo.")
    }

    /// Whisper treats the prompt as preceding transcript. Without the full
    /// stop, the first spoken word is read as continuing the last term.
    func testThePromptEndsWithAStop() {
        XCTAssertTrue(SpeechVocabulary.prompt(["Swift"])?.hasSuffix(".") == true)
    }

    func testAnEmptyListPrimesNothing() {
        XCTAssertNil(SpeechVocabulary.prompt([]))
    }

    /// The prompt window is 224 tokens and everything past it is discarded,
    /// taking the bias with it. A long list also dilutes what survives.
    func testTheListIsCapped() {
        let many = (1...500).map { "term\($0)" }
        XCTAssertEqual(SpeechVocabulary.capped(many).count, SpeechVocabulary.limit)
        let prompt = SpeechVocabulary.prompt(many) ?? ""
        XCTAssertLessThan(prompt.count, 1_000, "a prompt this long stops biasing")
    }

    func testShortListsAreNotTruncated() {
        XCTAssertEqual(SpeechVocabulary.capped(["a", "b"]), ["a", "b"])
    }

    // MARK: - The file

    func testDefaultsAreUsedWhenThereIsNoFile() {
        // Whatever is on this machine, the defaults must be a usable list on
        // their own -- most people will never open the file.
        XCTAssertFalse(SpeechVocabulary.defaults.isEmpty)
        XCTAssertNotNil(SpeechVocabulary.prompt(SpeechVocabulary.defaults))
    }

    func testDefaultsAvoidOnePersonsProjects() {
        // A list tuned to one codebase is worse than nothing for everyone
        // else. These are terms any developer dictating would use.
        for term in SpeechVocabulary.defaults {
            XCTAssertFalse(term.isEmpty)
            XCTAssertFalse(term.contains(","),
                           "\(term) would break the comma-separated prompt")
        }
    }

    func testTheFileSitsBesideTheOtherDictationFiles() {
        let path = SpeechVocabulary.fileURL.path
        XCTAssertTrue(path.hasSuffix("nib/vocabulary.txt"), path)
        XCTAssertFalse(path.contains(".app/"),
                       "a file inside the bundle is lost on every update")
    }

    // MARK: - Reading a written file

    /// Parsing is exercised against a real file rather than a string, because
    /// the comment and blank-line handling is the part someone editing by hand
    /// will actually hit.
    func testCommentsAndBlankLinesAreIgnored() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nib-vocab-\(UUID().uuidString).txt")
        try """
        # a comment

        Hasura
          useMemo
        # another comment
        GraphQL

        """.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let parsed = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        XCTAssertEqual(parsed, ["Hasura", "useMemo", "GraphQL"])
    }
}
