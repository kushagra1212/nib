import XCTest
@testable import nib

/// Underline placement, including the scroll cases that were drifting.
final class MarkPlacementTests: XCTestCase {
    private let field = CGRect(x: 100, y: 200, width: 400, height: 100)

    private func suggestion(_ location: Int = 0, _ length: Int = 4) -> Suggestion {
        Suggestion(range: NSRange(location: location, length: length),
                   message: "m", replacements: ["x"])
    }

    private func place(_ rects: [CGRect], in frame: CGRect? = nil)
        -> [(suggestion: Suggestion, rects: [CGRect])] {
        MarkPlacement.place(marks: [(suggestion(), rects)],
                            fieldFrame: frame ?? field)
    }

    // MARK: - coordinate conversion

    func testRectIsRelativeToTheField() {
        let result = place([CGRect(x: 150, y: 250, width: 40, height: 16)])
        XCTAssertEqual(result[0].rects[0], CGRect(x: 50, y: 50, width: 40, height: 16))
    }

    func testRectAtTheFieldOriginBecomesZero() {
        let result = place([CGRect(x: 100, y: 200, width: 10, height: 10)])
        XCTAssertEqual(result[0].rects[0].origin, .zero)
    }

    func testFieldAtNegativeOriginOnASecondaryDisplay() {
        // A display left of the primary reports negative x.
        let left = CGRect(x: -1800, y: 100, width: 400, height: 100)
        let result = place([CGRect(x: -1750, y: 150, width: 30, height: 14)], in: left)
        XCTAssertEqual(result[0].rects[0], CGRect(x: 50, y: 50, width: 30, height: 14))
    }

    // MARK: - clipping, which is what scrolling exercises

    func testRectFullyInsideIsKept() {
        XCTAssertEqual(place([CGRect(x: 150, y: 250, width: 40, height: 16)])[0].rects.count, 1)
    }

    func testRectFullyAboveTheFieldIsDropped() {
        // Scrolled off the top: still reports bounds, must not be drawn.
        XCTAssertTrue(place([CGRect(x: 150, y: 400, width: 40, height: 16)]).isEmpty)
    }

    func testRectFullyBelowTheFieldIsDropped() {
        XCTAssertTrue(place([CGRect(x: 150, y: 100, width: 40, height: 16)]).isEmpty)
    }

    func testRectLeftOfTheFieldIsDropped() {
        XCTAssertTrue(place([CGRect(x: 0, y: 250, width: 40, height: 16)]).isEmpty)
    }

    func testRectRightOfTheFieldIsDropped() {
        XCTAssertTrue(place([CGRect(x: 600, y: 250, width: 40, height: 16)]).isEmpty)
    }

    func testHalfScrolledRectIsTrimmedNotDropped() {
        // Mid-scroll a line straddles the top edge; underline only the visible
        // part rather than painting over the surrounding UI.
        let straddling = CGRect(x: 150, y: 290, width: 40, height: 20)
        let result = place([straddling])
        XCTAssertEqual(result.count, 1)
        let rect = result[0].rects[0]
        XCTAssertEqual(rect.maxY, 100, "clipped to the field's top edge")
    }

    func testRectWiderThanTheFieldIsTrimmed() {
        let wide = CGRect(x: 50, y: 250, width: 600, height: 16)
        let rect = place([wide])[0].rects[0]
        XCTAssertEqual(rect.minX, 0)
        XCTAssertEqual(rect.width, 400)
    }

    func testRectTouchingTheEdgeExactlyIsDropped() {
        // Zero-area intersection is not visible.
        XCTAssertTrue(place([CGRect(x: 150, y: 300, width: 40, height: 0)]).isEmpty)
    }

    // MARK: - multi-line marks

    func testEveryVisibleLineIsKept() {
        let lines = [
            CGRect(x: 110, y: 270, width: 380, height: 16),
            CGRect(x: 110, y: 250, width: 380, height: 16),
            CGRect(x: 110, y: 230, width: 200, height: 16),
        ]
        XCTAssertEqual(place(lines)[0].rects.count, 3)
    }

    func testPartlyScrolledSentenceKeepsOnlyVisibleLines() {
        let lines = [
            CGRect(x: 110, y: 400, width: 380, height: 16), // above, gone
            CGRect(x: 110, y: 250, width: 380, height: 16), // visible
            CGRect(x: 110, y: 100, width: 380, height: 16), // below, gone
        ]
        let result = place(lines)
        XCTAssertEqual(result[0].rects.count, 1)
        XCTAssertEqual(result[0].rects[0].origin.y, 50)
    }

    func testMarkWithNoVisibleLinesIsDroppedEntirely() {
        let lines = [
            CGRect(x: 110, y: 400, width: 380, height: 16),
            CGRect(x: 110, y: 100, width: 380, height: 16),
        ]
        XCTAssertTrue(place(lines).isEmpty)
    }

    // MARK: - batches

    func testSeveralMarksArePlacedIndependently() {
        let marks = [
            (suggestion(0, 4), [CGRect(x: 150, y: 250, width: 40, height: 16)]),
            (suggestion(9, 5), [CGRect(x: 300, y: 250, width: 50, height: 16)]),
        ]
        let result = MarkPlacement.place(marks: marks, fieldFrame: field)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].rects[0].origin.x, 50)
        XCTAssertEqual(result[1].rects[0].origin.x, 200)
    }

    func testOrderIsPreservedSoCorrectionsWinHitTesting() {
        let correction = Suggestion(kind: .correction, range: NSRange(location: 0, length: 4),
                                    message: "c", replacements: ["x"])
        let clarity = Suggestion(kind: .clarity, range: NSRange(location: 0, length: 40),
                                 message: "l", replacements: ["y"])
        let rect = [CGRect(x: 150, y: 250, width: 40, height: 16)]
        let result = MarkPlacement.place(marks: [(correction, rect), (clarity, rect)],
                                         fieldFrame: field)
        XCTAssertEqual(result[0].suggestion.kind, .correction)
    }

    func testEmptyInput() {
        XCTAssertTrue(MarkPlacement.place(marks: [], fieldFrame: field).isEmpty)
    }

    func testMarkWithNoRectsIsDropped() {
        XCTAssertTrue(MarkPlacement.place(marks: [(suggestion(), [])],
                                          fieldFrame: field).isEmpty)
    }

    func testZeroSizedFieldDropsEverything() {
        XCTAssertTrue(place([CGRect(x: 150, y: 250, width: 40, height: 16)],
                            in: .zero).isEmpty)
    }

    // MARK: - the scroll invariant

    func testScrollingShiftsEveryMarkByTheSameAmount() {
        // The field does not move when text scrolls inside it, so window-space
        // positions must shift by exactly the scroll delta.
        let before = [CGRect(x: 150, y: 260, width: 40, height: 16),
                      CGRect(x: 150, y: 240, width: 40, height: 16)]
        let delta: CGFloat = 20
        let after = before.map { $0.offsetBy(dx: 0, dy: delta) }

        let placedBefore = place(before)[0].rects
        let placedAfter = place(after)[0].rects
        for (a, b) in zip(placedBefore, placedAfter) {
            XCTAssertEqual(b.origin.y - a.origin.y, delta)
        }
    }
}
