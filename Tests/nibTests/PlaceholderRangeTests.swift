import XCTest
@testable import nib

/// A range that means "all of this text" must never be written back as a
/// position in the document.
///
/// When a field will not report a range that matches the selection it just
/// gave us, nib keeps the selected text alone and its range becomes
/// 0..<length. That is a placeholder. The writer used to set it as the
/// selected range, which in Obsidian highlighted the opening of the note and
/// typed the rewrite over it -- leaving the replaced words stranded at the end
/// of a paragraph elsewhere in the document.
final class PlaceholderRangeTests: XCTestCase {
    private let selection = "Fixing this events and getting the video of other event"

    /// A field whose reported range matches: the range is a real position and
    /// the writer may use it.
    func testAVerifiedRangeIsMarkedAbsolute() {
        let full = "Some earlier text. " + selection + " And some after."
        let range = (full as NSString).range(of: selection)
        XCTAssertTrue(TextGrabber.rangeSelects(selection, in: full, at: range),
                      "premise: this is the case that keeps the whole field")

        let target = TextTarget(text: full, range: range,
                                source: .clipboard, hadSelection: true)
        XCTAssertTrue(target.rangeIsAbsolute, "the default must stay absolute")
        XCTAssertEqual(target.selectedText, selection)
    }

    /// The Obsidian case: only the selection is kept, and its range covers all
    /// of it rather than pointing anywhere.
    func testTheFallbackTargetIsMarkedNotAbsolute() {
        let target = TextTarget(
            text: selection,
            range: NSRange(location: 0, length: (selection as NSString).length),
            source: .clipboard, hadSelection: true, rangeIsAbsolute: false)

        XCTAssertFalse(target.rangeIsAbsolute)
        XCTAssertEqual(target.selectedText, selection,
                       "the text is still right -- only the range is a placeholder")
    }

    /// The distinction the writer depends on. Both targets carry range
    /// location 0, and only the flag separates "the start of the document"
    /// from "all of this string".
    func testLocationZeroIsAmbiguousWithoutTheFlag() {
        let placeholder = TextTarget(
            text: selection,
            range: NSRange(location: 0, length: (selection as NSString).length),
            source: .clipboard, hadSelection: true, rangeIsAbsolute: false)
        let genuine = TextTarget(
            text: selection + " and more after it.",
            range: NSRange(location: 0, length: (selection as NSString).length),
            source: .clipboard, hadSelection: true)

        XCTAssertEqual(placeholder.range, genuine.range,
                       "identical ranges, opposite meanings")
        XCTAssertNotEqual(placeholder.rangeIsAbsolute, genuine.rangeIsAbsolute)
    }
}
