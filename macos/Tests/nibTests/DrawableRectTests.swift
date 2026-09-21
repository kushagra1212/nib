import XCTest
@testable import nib

/// The rule that decides whether an app's answer to `kAXBoundsForRange` is a
/// real place on screen. Slack answers every range with `0,982 0x0`, which is
/// not nil and therefore read as success for a long time.
final class DrawableRectTests: XCTestCase {
    func testOrdinaryRectIsDrawable() {
        XCTAssertTrue(AXElement.isDrawable(CGRect(x: 100, y: 200, width: 42, height: 17)))
    }

    func testSlackEmptyRectIsNotDrawable() {
        XCTAssertFalse(AXElement.isDrawable(CGRect(x: 0, y: 982, width: 0, height: 0)))
    }

    func testZeroWidthIsNotDrawable() {
        XCTAssertFalse(AXElement.isDrawable(CGRect(x: 10, y: 10, width: 0, height: 17)))
    }

    func testZeroHeightIsNotDrawable() {
        XCTAssertFalse(AXElement.isDrawable(CGRect(x: 10, y: 10, width: 42, height: 0)))
    }

    func testNegativeSizeIsNotDrawable() {
        XCTAssertFalse(AXElement.isDrawable(CGRect(x: 10, y: 10, width: -42, height: 17)))
    }

    /// A collapsed caret at the very start of an empty field.
    func testCaretAtOriginIsNotDrawable() {
        XCTAssertFalse(AXElement.isDrawable(.zero))
    }

    func testSubPixelRectIsStillDrawable() {
        XCTAssertTrue(AXElement.isDrawable(CGRect(x: 0, y: 0, width: 0.5, height: 0.5)))
    }

    /// Off-screen is a placement question, not a validity one -- clipping to the
    /// field frame handles it, so bounds must not reject it here.
    func testNegativeOriginIsDrawable() {
        XCTAssertTrue(AXElement.isDrawable(CGRect(x: -80, y: -40, width: 42, height: 17)))
    }

    func testInfiniteSizeIsNotDrawable() {
        let infinity = CGFloat.infinity
        XCTAssertFalse(AXElement.isDrawable(CGRect(x: 0, y: 0, width: infinity, height: 17)))
        XCTAssertFalse(AXElement.isDrawable(CGRect.infinite))
    }

    func testNaNIsNotDrawable() {
        let nan = CGFloat.nan
        XCTAssertFalse(AXElement.isDrawable(CGRect(x: nan, y: 0, width: 42, height: 17)))
        XCTAssertFalse(AXElement.isDrawable(CGRect(x: 0, y: 0, width: nan, height: 17)))
        XCTAssertFalse(AXElement.isDrawable(CGRect(x: 0, y: nan, width: 42, height: 17)))
    }

    func testNullRectIsNotDrawable() {
        XCTAssertFalse(AXElement.isDrawable(.null))
    }
}
