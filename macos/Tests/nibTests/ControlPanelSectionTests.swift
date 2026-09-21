import XCTest
@testable import nib

final class ControlPanelSectionTests: XCTestCase {
    /// Status is first because the window exists to answer "what is broken".
    func testStatusComesFirst() {
        XCTAssertEqual(ControlPanelSection.allCases.first, .status)
    }

    func testEverySectionHasATitleAndSymbol() {
        for section in ControlPanelSection.allCases {
            XCTAssertFalse(section.title.isEmpty, "\(section) has no title")
            XCTAssertFalse(section.symbol.isEmpty, "\(section) has no symbol")
        }
    }

    /// Phase 1 ships one section. The others arrive with the work that fills
    /// them, rather than as empty panes that look like a broken app.
    func testPhaseOneShipsStatusOnly() {
        XCTAssertEqual(ControlPanelSection.allCases, [.status])
    }
}
