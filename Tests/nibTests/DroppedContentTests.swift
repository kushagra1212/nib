import XCTest
@testable import nib

/// Rewrites that quietly delete part of what was written.
///
/// The strings here are verbatim: the input is what was typed, the output is
/// what Qwen3 0.6B actually returned for it.
final class DroppedContentTests: XCTestCase {
    private var checker: ModelChecker!

    override func setUp() async throws {
        // Only the pure judgement is exercised; no server is started.
        let config = RewriteEngine.Config(
            serverBinary: URL(fileURLWithPath: "/nonexistent"),
            modelPath: URL(fileURLWithPath: "/nonexistent")
        )
        checker = ModelChecker(rewriter: RewriteEngine(config: config))
    }

    /// Typed into Slack, then "Fix" pressed. Four words vanished off the end
    /// and every existing gate passed it: the word count barely moved, and
    /// four words out of thirty-three leaves the characters nearly identical.
    private let typed = "can  also scroll to top of the catalog so that after "
        + "navigation product can be shown directly instead user has to scroll "
        + "to top to see the product that they click on product details 3 options"

    private let returned = "Can also scroll to the top of the catalog so that "
        + "after navigation, product details can be shown directly instead of "
        + "the user having to scroll to the top to see the product that they "
        + "click on."

    func testCatchesTheReportedDeletion() {
        XCTAssertTrue(checker.dropsContent(original: typed, corrected: returned))
    }

    func testCountsTheWordsThatWentMissing() {
        // "product details 3 options"
        XCTAssertEqual(
            checker.longestDroppedRun(original: typed, corrected: returned), 4)
    }

    /// The gates that were already there both pass this, which is why it
    /// reached the screen. If either ever starts catching it, this test says so
    /// and the new one can go.
    func testTheOlderGatesDoNotCatchIt() {
        XCTAssertTrue(checker.isTrustworthy(original: typed, corrected: returned),
                      "word ratio and character similarity both pass a deletion")
    }

    // MARK: - Real corrections must still get through

    /// Three of five words change here, but singly, which is what correcting
    /// spelling looks like.
    func testSpellingCorrectionsAreNotDeletions() {
        XCTAssertFalse(checker.dropsContent(
            original: "Their is many erors in this sentance.",
            corrected: "There are many errors in this sentence."))
    }

    func testVerbCorrectionsAreNotDeletions() {
        XCTAssertFalse(checker.dropsContent(
            original: "we was going to the store and buyed milk, it dont work",
            corrected: "We were going to the store and bought milk. It doesn't work."))
    }

    func testIdenticalTextDropsNothing() {
        let text = "The quick brown fox jumps over the lazy dog."
        XCTAssertFalse(checker.dropsContent(original: text, corrected: text))
        XCTAssertEqual(checker.longestDroppedRun(original: text, corrected: text), 0)
    }

    /// Splitting a comma splice adds a full stop and changes nothing else.
    func testSplittingASentenceDropsNothing() {
        XCTAssertFalse(checker.dropsContent(
            original: "there is a bug, it is not exactly a bug",
            corrected: "There is a bug. It is not exactly a bug."))
    }

    // MARK: - The boundary

    func testTwoMissingWordsIsAllowed() {
        // Two in a row reads as a correction; three reads as a deletion.
        XCTAssertEqual(
            checker.longestDroppedRun(original: "keep one two three four",
                                      corrected: "keep three four"), 2)
        XCTAssertFalse(checker.dropsContent(original: "keep one two three four",
                                            corrected: "keep three four"))
    }

    func testThreeMissingWordsIsADeletion() {
        XCTAssertTrue(checker.dropsContent(original: "keep one two three four",
                                           corrected: "keep four"))
    }

    /// A deletion in the middle counts the same as one off the end.
    func testCatchesADeletionInTheMiddle() {
        XCTAssertTrue(checker.dropsContent(
            original: "the report covers March April and May figures",
            corrected: "the report covers figures"))
    }

    func testEmptyRewriteDropsEverything() {
        XCTAssertEqual(
            checker.longestDroppedRun(original: "one two three", corrected: ""), 3)
    }

    func testEmptyOriginalIsNotADeletion() {
        XCTAssertFalse(checker.dropsContent(original: "", corrected: "anything"))
    }
}
