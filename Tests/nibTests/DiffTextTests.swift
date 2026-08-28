import AppKit
import XCTest
@testable import nib

/// Covers the card's inline diff. It slices the surrounding sentence by UTF-16
/// offset, so a mistake here either crashes on an emoji or shows the wrong
/// words around the change.
final class DiffTextTests: XCTestCase {
    private func suggestion(_ location: Int, _ length: Int) -> Suggestion {
        Suggestion(range: NSRange(location: location, length: length),
                   message: "m", replacements: [])
    }

    private func render(_ s: Suggestion, _ replacement: String,
                        _ context: String) -> String {
        FixCard.diffText(s, replacement: replacement, context: context).string
    }

    func testShowsOldAndNewTogether() {
        let out = render(suggestion(0, 5), "There", "Their is many")
        XCTAssertTrue(out.contains("Their"), out)
        XCTAssertTrue(out.contains("There"), out)
    }

    func testIncludesTrailingContext() {
        let out = render(suggestion(0, 5), "There", "Their is many")
        XCTAssertTrue(out.contains("is many"), out)
    }

    func testIncludesLeadingContext() {
        let out = render(suggestion(13, 5), "There", "Honest state Their")
        XCTAssertTrue(out.contains("Honest state"), out)
    }

    func testOutOfBoundsRangeFallsBackToTheReplacement() {
        XCTAssertEqual(render(suggestion(500, 5), "There", "short"), "There")
    }

    func testRangeStraddlingTheEndFallsBack() {
        XCTAssertEqual(render(suggestion(3, 99), "There", "short"), "There")
    }

    func testEmojiInContextDoesNotCorruptTheSlice() {
        // Offsets are UTF-16; "bad" sits at 3 after a two-unit emoji.
        let out = render(suggestion(3, 3), "good", "😀 bad ending")
        XCTAssertTrue(out.contains("good"), out)
        XCTAssertTrue(out.contains("bad"), out)
    }

    func testLongLeadingContextIsElided() {
        let long = String(repeating: "word ", count: 40)
        let out = render(suggestion((long as NSString).length, 3), "XYZ", long + "abc")
        XCTAssertTrue(out.contains("…"), "expected an ellipsis, got: \(out)")
    }

    func testLongTrailingContextIsElided() {
        let tail = String(repeating: " word", count: 40)
        let out = render(suggestion(0, 3), "XYZ", "abc" + tail)
        XCTAssertTrue(out.contains("…"), "expected an ellipsis, got: \(out)")
    }

    func testShortContextIsNotElided() {
        let out = render(suggestion(0, 5), "There", "Their is")
        XCTAssertFalse(out.contains("…"), out)
    }

    func testEmptyContext() {
        XCTAssertEqual(render(suggestion(0, 0), "x", ""), " x")
    }

    func testStrikethroughIsAppliedToTheOriginalOnly() {
        let attributed = FixCard.diffText(suggestion(0, 5), replacement: "There",
                                          context: "Their is many")
        var struckRanges: [NSRange] = []
        attributed.enumerateAttribute(
            .strikethroughStyle,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, range, _ in
            if value != nil { struckRanges.append(range) }
        }
        XCTAssertEqual(struckRanges.count, 1)
        XCTAssertEqual(attributed.string(from: struckRanges[0]), "Their")
    }
}

private extension NSAttributedString {
    func string(from range: NSRange) -> String {
        (string as NSString).substring(with: range)
    }
}
