import XCTest
@testable import nib

/// Whether a reported selection range really points at the reported selection.
///
/// nib reads the selected text, then prefers the whole field plus the selected
/// range so a rewrite can see context. The check on that range used to be
/// "does it fit", which is not the same question as "is it right".
///
/// Obsidian is where the difference showed. CodeMirror 6 virtualises, so the
/// value exposed over accessibility is only the rendered lines -- it grew from
/// 1841 to 2054 characters just by scrolling -- while the selected range is
/// reported against a different basis. An offset range still fits, so the old
/// check passed and nib spoke a paragraph from earlier in the document.
final class SelectionRangeTests: XCTestCase {
    private let full = "The first paragraph is here. "
        + "The second paragraph follows it. "
        + "The third paragraph is the one selected."

    func testATrueRangeIsAccepted() {
        let selected = "The third paragraph is the one selected."
        let range = (full as NSString).range(of: selected)
        XCTAssertTrue(TextGrabber.rangeSelects(selected, in: full, at: range))
    }

    /// The Obsidian case. In bounds, wrong place.
    func testAnOffsetRangeThatStillFitsIsRejected() {
        let selected = "The third paragraph is the one selected."
        var range = (full as NSString).range(of: selected)
        range.location -= 29          // one paragraph earlier, still in bounds
        XCTAssertLessThanOrEqual(NSMaxRange(range), (full as NSString).length,
                                 "the premise: an offset range can still fit")
        XCTAssertFalse(TextGrabber.rangeSelects(selected, in: full, at: range),
                       "an offset range must not pass just because it fits")
    }

    func testARangeRunningPastTheEndIsRejected() {
        let range = NSRange(location: (full as NSString).length - 5, length: 50)
        XCTAssertFalse(TextGrabber.rangeSelects("anything", in: full, at: range))
    }

    /// Virtualised fields report ranges against the whole document while
    /// exposing only part of it, so the location alone can exceed the value.
    func testALocationBeyondTheRenderedValueIsRejected() {
        let range = NSRange(location: 5_000, length: 10)
        XCTAssertFalse(TextGrabber.rangeSelects("anything", in: full, at: range))
    }

    func testANegativeLocationIsRejected() {
        XCTAssertFalse(TextGrabber.rangeSelects(
            "x", in: full, at: NSRange(location: -1, length: 3)))
    }

    /// Same length, different text -- the case a length-only check would miss.
    func testARangeOfTheRightLengthInTheWrongPlaceIsRejected() {
        let selected = "first"
        let wrong = (full as NSString).range(of: "third")
        XCTAssertEqual(wrong.length, (selected as NSString).length)
        XCTAssertFalse(TextGrabber.rangeSelects(selected, in: full, at: wrong))
    }
}
