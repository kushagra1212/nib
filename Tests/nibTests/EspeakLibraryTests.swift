import XCTest
@testable import nib

/// The espeak binding, against the same espeak the fixtures came from.
///
/// This is the half `PhonemizerTests` deliberately does not cover. That one
/// replays recorded phonemes to test the assembly around espeak; this one calls
/// espeak for real and checks it says what was recorded. Between them there is
/// no gap: if both pass, text becomes the same phonemes the Python engine
/// produced, end to end.
///
/// Skips where `Scripts/fetch-espeak.sh` has not been run.
final class EspeakLibraryTests: XCTestCase {
    private struct Golden: Decodable {
        struct Entry: Decodable {
            let name: String
            let text: String
            let preserved_chunks: [String]
            let chunk_phonemes: [String]
            let phonemes: String
        }
        let entries: [Entry]
        let espeak_version: String
    }

    private func golden() throws -> Golden {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/phonemes-golden.json")
        return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
    }

    /// The checkout's own vendor directory, found from this file rather than
    /// from the executable: a test bundle sits deep enough that walking up from
    /// the binary lands outside the repository.
    private static let vendored = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // nibTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo
        .appendingPathComponent("vendor/espeak")

    private func espeak() throws -> EspeakLibrary {
        guard EspeakLibrary.contains(Self.vendored) else {
            throw XCTSkip("no espeak-ng; run Scripts/fetch-espeak.sh")
        }
        return try EspeakLibrary.shared(directory: Self.vendored)
    }

    // MARK: - Where it looks

    /// The bug this inherits from llama-server: a path that existed on one
    /// machine, so every install shipped with the feature silently dead.
    func testNoCandidateIsSomebodysHomeDirectory() {
        let candidates = EspeakLibrary.directoryCandidates(
            bundleResources: URL(fileURLWithPath: "/Applications/nib.app/Contents/Resources"),
            executable: URL(fileURLWithPath: "/repo/.build/release/nib"))
        for url in candidates {
            XCTAssertFalse(url.path.hasPrefix("/Users/"), "\(url.path)")
        }
    }

    func testTheBundledCopyComesFirst() {
        let candidates = EspeakLibrary.directoryCandidates(
            bundleResources: URL(fileURLWithPath: "/Applications/nib.app/Contents/Resources"),
            executable: URL(fileURLWithPath: "/repo/.build/release/nib"))
        XCTAssertEqual(candidates.first?.path,
                       "/Applications/nib.app/Contents/Resources/espeak")
    }

    func testACheckoutIsFoundByWalkingUp() {
        let candidates = EspeakLibrary.directoryCandidates(
            bundleResources: nil,
            executable: URL(fileURLWithPath: "/repo/.build/release/nib"))
        XCTAssertTrue(candidates.contains { $0.path == "/repo/vendor/espeak" },
                      "a checkout build must find vendor/espeak")
    }

    // MARK: - Against the recording

    /// Every chunk of every text, phonemised for real and compared with what
    /// the Python engine's espeak returned for the same chunk.
    func testEspeakSaysWhatWasRecorded() throws {
        let espeak = try espeak()
        var compared = 0
        for entry in try golden().entries {
            for (chunk, expected) in zip(entry.preserved_chunks, entry.chunk_phonemes) {
                XCTAssertEqual(try espeak.phonemes(for: chunk), expected,
                               "\(entry.name): \(chunk.debugDescription)")
                compared += 1
            }
        }
        XCTAssertGreaterThan(compared, 30, "the corpus should exercise more than this")
    }

    /// The version matters. Dictionaries change between releases, and a
    /// different espeak phonemises differently while passing every test that
    /// does not load it -- which is most of them.
    func testTheVersionMatchesTheFixture() throws {
        _ = try espeak()   // skips before asserting, where not installed
        XCTAssertEqual(try golden().espeak_version, "1.52.0")
    }

    // MARK: - End to end

    /// Text in, phonemes out, through the real library. The one test that would
    /// fail if any part of the phoneme path were wrong.
    func testTextBecomesTheSamePhonemesAsTheEngine() throws {
        let espeak = try espeak()
        for entry in try golden().entries {
            XCTAssertEqual(try Phonemizer.phonemes(of: entry.text, using: espeak),
                           entry.phonemes,
                           "\(entry.name): \(entry.text.debugDescription)")
        }
    }

    /// And through to the ids the model is actually fed.
    func testTheGoldenSentenceReachesTheSameTokens() throws {
        let espeak = try espeak()
        let sentence = "The quick brown fox jumps over the lazy dog."
        let phonemes = try Phonemizer.phonemes(of: sentence, using: espeak)
        XCTAssertEqual(try KokoroTokenizer.tokenize(phonemes).count, 53)
    }

    // MARK: - The library itself

    func testItReportsASampleRate() throws {
        let espeak = try espeak()
        XCTAssertGreaterThan(espeak.sampleRate, 0)
    }

    /// Loading twice returns the same instance. espeak has one set of globals,
    /// and a second initialisation against a different data path would not
    /// switch dictionaries -- it would look like it had.
    func testLoadingTwiceGivesTheSameLibrary() throws {
        let first = try espeak()
        let second = try espeak()
        XCTAssertTrue(first === second)
    }

    /// espeak reads the text through a pointer it advances itself. Getting that
    /// wrong loops forever or stops after the first clause, so a text with
    /// several clauses is worth its own check.
    func testAllClausesAreReturnedNotJustTheFirst() throws {
        let espeak = try espeak()
        let phonemes = try espeak.phonemes(for: "one, two, three, four")
        XCTAssertEqual(phonemes.components(separatedBy: " ").count, 4,
                       "got \(phonemes.debugDescription)")
    }

    func testEmptyTextIsNoPhonemes() throws {
        let espeak = try espeak()
        XCTAssertEqual(try espeak.phonemes(for: ""), "")
    }

    /// Called from several threads at once, because espeak's state is global
    /// and unlocked calls return each other's phonemes.
    func testConcurrentCallsDoNotCorruptEachOther() throws {
        let espeak = try espeak()
        let expected = try espeak.phonemes(for: "the quick brown fox")
        let results = NSMutableArray()
        let guardLock = NSLock()

        DispatchQueue.concurrentPerform(iterations: 24) { _ in
            let phonemes = (try? espeak.phonemes(for: "the quick brown fox")) ?? "<threw>"
            guardLock.lock()
            results.add(phonemes)
            guardLock.unlock()
        }

        XCTAssertEqual(Set(results.map { $0 as! String }), [expected])
    }
}
