import AppKit
import XCTest
@testable import nib

/// A Dock icon that appears and never leaves is worse than none, so the rule
/// is asserted rather than left to whoever calls it last.
final class ActivationPolicyTests: XCTestCase {
    func testNoWindowsMeansMenuBarOnly() {
        XCTAssertEqual(ActivationPolicy.desired(openWindows: 0), .accessory)
    }

    func testAnyOpenWindowMeansRegular() {
        XCTAssertEqual(ActivationPolicy.desired(openWindows: 1), .regular)
        XCTAssertEqual(ActivationPolicy.desired(openWindows: 4), .regular)
    }

    /// Closing one of two windows must not drop the Dock icon while the other
    /// is still on screen.
    func testCountIsWhatMattersNotAFlag() {
        XCTAssertEqual(ActivationPolicy.desired(openWindows: 2), .regular)
        XCTAssertEqual(ActivationPolicy.desired(openWindows: 1), .regular)
        XCTAssertEqual(ActivationPolicy.desired(openWindows: 0), .accessory)
    }

    func testNegativeCountIsTreatedAsNone() {
        // Defensive: an unbalanced close should not leave a Dock icon behind.
        XCTAssertEqual(ActivationPolicy.desired(openWindows: -1), .accessory)
    }
}
