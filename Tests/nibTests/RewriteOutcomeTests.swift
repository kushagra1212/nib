import XCTest
@testable import nib

/// Telling "your writing is fine" apart from "the rewrite was rejected".
///
/// These two used to be the same value. `ModelChecker` refuses a rewrite that
/// changes the meaning by returning the original text, and the selection bar
/// compared the result with the original to decide there was nothing to fix --
/// so a rejected rewrite was reported as "looks good" in green.
///
/// That was reported as "I select text and see a popup but no result". The
/// sentence was a question, the model answered it instead of rewriting it,
/// `flipsQuestion` correctly threw the answer away (see `QuestionTests`), and
/// the bar then claimed the question was well written.
///
/// Green over unchecked writing is the failure this codebase has now made
/// twice; the first was reporting "looks good" with no model installed.
final class RewriteOutcomeTests: XCTestCase {
    func testOnlyARewriteCarriesText() {
        XCTAssertEqual(RewriteOutcome.rewritten("better").text, "better")
        XCTAssertNil(RewriteOutcome.unchanged.text)
        XCTAssertNil(RewriteOutcome.refused("changed the meaning").text)
    }

    /// The distinction the bar depends on. If these ever compare equal, the
    /// bug is back.
    func testARefusalIsNotTheSameAsUnchanged() {
        XCTAssertNotEqual(RewriteOutcome.refused("cut off the ending"),
                          RewriteOutcome.unchanged)
    }

    /// A refusal has to say why. Without a reason the bar has nothing to show
    /// and falls back to looking like the button did nothing at all.
    func testARefusalCarriesAReason() {
        guard case .refused(let why) = RewriteOutcome.refused("dropped a clause")
        else { return XCTFail("not a refusal") }
        XCTAssertFalse(why.isEmpty)
    }

    /// Two refusals for different reasons are different values, so the bar
    /// shows the one that actually happened.
    func testRefusalsAreDistinguishedByReason() {
        XCTAssertNotEqual(RewriteOutcome.refused("cut off the ending"),
                          RewriteOutcome.refused("dropped part of what you wrote"))
    }
}
