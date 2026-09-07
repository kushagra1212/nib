import XCTest
@testable import nib

/// Telling a truncated rewrite apart from a reordered one.
///
/// The tail count asks how many of the original's last words fall after the
/// last word that survived. It cannot tell "the model stopped early" from "the
/// model moved the ending", and rewriting moves endings constantly -- so a
/// 29-word sentence with no mistakes in it was refused for cutting off an
/// ending that was still there, in full, in a different order.
final class UnfinishedRewriteTests: XCTestCase {
    /// The sentence from the report.
    private let original = "can you check the logs now I am login again an "
        + "existing user so that I can confirm it only runs for first time "
        + "login for a particular user"

    /// Only the pure judgement is exercised; no server is started.
    private func makeChecker() -> ModelChecker {
        let config = RewriteEngine.Config(
            serverBinary: URL(fileURLWithPath: "/nonexistent"),
            modelPath: URL(fileURLWithPath: "/nonexistent"))
        return ModelChecker(rewriter: RewriteEngine(config: config))
    }

    func testAFinishedSentenceIsNotUnfinished() {
        for ending in ["It runs on a user's first login.",
                       "Does it run on first login?",
                       "Run it now!",
                       "He said \"go\"",
                       "(as above)"] {
            XCTAssertFalse(ModelChecker.looksUnfinished(ending), ending)
        }
    }

    func testASentenceStoppingMidWayIsUnfinished() {
        for ending in ["Can you check the logs now, I am logging in again as",
                       "It only runs for the first",
                       ""] {
            XCTAssertTrue(ModelChecker.looksUnfinished(ending), ending)
        }
    }

    func testTrailingWhitespaceDoesNotHideTheEnding() {
        XCTAssertFalse(ModelChecker.looksUnfinished("All done.   \n"))
    }

    /// The false refusal itself: the tail no longer lines up, because the
    /// rewrite moved it -- but every word is present and it ends properly.
    func testAReorderedEndingIsNotTreatedAsTruncated() {
        let checker = makeChecker()
        let rewritten = "Can you check the logs now? I am logging in again as "
            + "an existing user, so I can confirm it only runs on a particular "
            + "user's first login."

        XCTAssertGreaterThanOrEqual(
            checker.droppedTail(original: original, corrected: rewritten), 3,
            "premise: the tail count alone still flags this")
        XCTAssertFalse(ModelChecker.looksUnfinished(rewritten),
                       "so the second condition is what has to save it")
    }

    /// The guard still has to work. A rewrite that really stops halfway is
    /// caught by both conditions.
    func testARealTruncationIsStillCaught() {
        let checker = makeChecker()
        let rewritten = "Can you check the logs now? I am logging in again as an"

        XCTAssertGreaterThanOrEqual(
            checker.droppedTail(original: original, corrected: rewritten), 3)
        XCTAssertTrue(ModelChecker.looksUnfinished(rewritten))
    }
}
