import XCTest
@testable import nib

/// How many tokens a rewrite is allowed to produce.
///
/// The budget knew about the policy ceiling and not about the context window,
/// so a long selection asked for more tokens than the window could hold. The
/// reply was cut off, the guard downstream saw an ending that was missing and
/// refused it, and the bar said "that rewrite cut off the ending" about text
/// with nothing wrong with it. Every test here is that bug from one side.
final class TokenBudgetTests: XCTestCase {
    private let context = 2048

    /// The invariant the old version could violate. Prompt and reply share one
    /// window; a budget that ignores the prompt buys a truncated reply.
    ///
    /// Stated against the headroom rather than the window, because a selection
    /// large enough to fill the window on its own cannot be rewritten at any
    /// budget -- `rewrite` refuses those up front instead.
    func testBudgetNeverExceedsWhatIsLeftOfTheWindow() {
        for characters in [0, 40, 400, 1_000, 4_000, 20_000] {
            let text = String(repeating: "a", count: characters)
            let budget = RewriteEngine.tokenBudget(
                for: text, limit: 1024, context: context)
            XCTAssertLessThanOrEqual(
                budget, RewriteEngine.headroom(for: text, context: context),
                "budget for \(characters) chars overruns the headroom")
            XCTAssertLessThanOrEqual(budget, 1024, "policy ceiling ignored")
        }
    }

    /// For anything nib will actually attempt, the whole exchange fits.
    func testEverythingNibAttemptsFitsInOnePass() {
        for characters in [0, 40, 400, 1_000, 4_000] {
            let text = String(repeating: "a", count: characters)
            guard characters / 4 + RewriteEngine.promptOverhead < context else { continue }
            let budget = RewriteEngine.tokenBudget(
                for: text, limit: 1024, context: context)
            XCTAssertLessThanOrEqual(
                characters / 4 + RewriteEngine.promptOverhead + budget, context,
                "the exchange for \(characters) chars does not fit the window")
        }
    }

    /// The case from the report. A long paragraph used to clamp to a flat 512
    /// against input that needed more than that, so it could not have finished.
    func testALongSelectionIsNotGivenLessRoomThanItsOwnInput() {
        let text = String(repeating: "word ", count: 200)   // ~1000 chars
        let budget = RewriteEngine.tokenBudget(
            for: text, limit: 1024, context: context)
        XCTAssertGreaterThan(budget, text.count / 4,
                             "a rewrite may not be capped below its own input")
    }

    /// Native English expands: idiomatic phrasing is often longer than what it
    /// replaces, so a budget sized for a correction clips a translation.
    func testShortTextStillGetsWorkingRoom() {
        let budget = RewriteEngine.tokenBudget(
            for: "i has went there", limit: 1024, context: context)
        XCTAssertGreaterThanOrEqual(budget, 128)
    }

    /// A selection far larger than the window still returns something usable
    /// rather than zero or a negative number.
    func testAnOversizedSelectionStillLeavesAFloor() {
        let text = String(repeating: "a", count: 100_000)
        let budget = RewriteEngine.tokenBudget(
            for: text, limit: 1024, context: context)
        XCTAssertGreaterThanOrEqual(budget, 128)
    }
}
