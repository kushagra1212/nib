import XCTest
@testable import nib

/// Keeping the last hundred transcripts.
///
/// Dictation types into whatever has focus, so a transcript that lands in the
/// wrong window, or in a field cleared a moment later, is gone with nothing to
/// scroll back to. This is the thing to scroll back to.
final class DictationHistoryTests: XCTestCase {
    func testNewestComesFirst() {
        var history = DictationHistory()
        history.add("first")
        history.add("second")
        XCTAssertEqual(history.entries.map(\.text), ["second", "first"])
    }

    /// A hundred, as asked for. The oldest goes when the newest arrives.
    func testItKeepsAHundred() {
        var history = DictationHistory()
        for index in 1...120 { history.add("line \(index)") }
        XCTAssertEqual(history.entries.count, DictationHistory.limit)
        XCTAssertEqual(history.entries.first?.text, "line 120")
        XCTAssertEqual(history.entries.last?.text, "line 21")
    }

    /// Repeating a failed dictation is the commonest reason to say the same
    /// thing twice, and two identical rows help nobody find anything.
    func testTheSameThingTwiceRunningIsOneEntry() {
        var history = DictationHistory()
        history.add("hello there")
        history.add("hello there")
        XCTAssertEqual(history.entries.count, 1)
    }

    /// But the same words again later are a real second entry: you said it
    /// twice for a reason and may want either.
    func testTheSameThingLaterIsItsOwnEntry() {
        var history = DictationHistory()
        history.add("hello there")
        history.add("something else")
        history.add("hello there")
        XCTAssertEqual(history.entries.count, 3)
    }

    func testEmptyAndWhitespaceAreNotKept() {
        var history = DictationHistory()
        history.add("")
        history.add("   \n  ")
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testSurroundingWhitespaceIsTrimmed() {
        var history = DictationHistory()
        history.add("  spoken words  ")
        XCTAssertEqual(history.entries.first?.text, "spoken words")
    }

    // MARK: - The menu label

    /// The middle is cut, not the tail. Two dictations that begin the same way
    /// are told apart by how they end, and a list truncated at a common prefix
    /// is unreadable.
    func testLongEntriesKeepBothEnds() {
        let text = "the beginning of a long dictation that goes on for a while "
            + "before finally reaching its own distinctive ending"
        let label = DictationHistory.Entry(text: text, date: Date()).label()
        XCTAssertTrue(label.hasPrefix("the beginning"), label)
        XCTAssertTrue(label.hasSuffix("distinctive ending"), label)
        XCTAssertTrue(label.contains("…"))
    }

    func testShortEntriesAreNotTruncated() {
        let entry = DictationHistory.Entry(text: "a short one", date: Date())
        XCTAssertEqual(entry.label(), "a short one")
    }

    /// Newlines would break a menu row in two.
    func testNewlinesAreFlattenedForTheMenu() {
        let entry = DictationHistory.Entry(text: "line one\nline two", date: Date())
        XCTAssertEqual(entry.label(), "line one line two")
        XCTAssertFalse(entry.label().contains("\n"))
    }

    // MARK: - On disk

    func testItSurvivesARestart() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nib-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        var history = DictationHistory()
        history.add("something worth keeping")
        history.save(to: url)

        XCTAssertEqual(DictationHistory.load(from: url).entries.map(\.text),
                       ["something worth keeping"])
    }

    /// It is a record of things said at a desk. The default for a new file in
    /// Application Support is readable by anyone on the machine.
    func testTheFileIsReadableOnlyByItsOwner() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nib-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        var history = DictationHistory()
        history.add("private words")
        history.save(to: url)

        let mode = try FileManager.default
            .attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.int16Value, 0o600)
    }

    func testMissingFileIsAnEmptyHistoryRatherThanAFailure() {
        let missing = URL(fileURLWithPath: "/nonexistent/nib-history.json")
        XCTAssertTrue(DictationHistory.load(from: missing).entries.isEmpty)
    }

    /// A file written by a build with a larger limit must not grow this one's
    /// menu without bound.
    func testAnOversizedFileIsTrimmedOnRead() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nib-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let many = (1...250).map {
            DictationHistory.Entry(text: "line \($0)", date: Date())
        }
        try JSONEncoder().encode(many).write(to: url)
        XCTAssertEqual(DictationHistory.load(from: url).entries.count,
                       DictationHistory.limit)
    }

    func testClearingRemovesEverything() {
        var history = DictationHistory()
        history.add("one")
        history.add("two")
        history.clear()
        XCTAssertTrue(history.entries.isEmpty)
    }
}
