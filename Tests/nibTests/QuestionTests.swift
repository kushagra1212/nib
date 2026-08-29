import XCTest
@testable import nib

/// Rewrites that answer a different sentence from the one that was written.
final class QuestionTests: XCTestCase {
    private var checker: ModelChecker!

    override func setUp() async throws {
        let config = RewriteEngine.Config(
            serverBinary: URL(fileURLWithPath: "/nonexistent"),
            modelPath: URL(fileURLWithPath: "/nonexistent")
        )
        checker = ModelChecker(rewriter: RewriteEngine(config: config))
    }

    /// The reported case, verbatim. Asked whether an approach was safe, and
    /// told that it is.
    func testCatchesTheReportedFlip() {
        XCTAssertTrue(checker.flipsQuestion(
            original: "The approach A which you have given, is this safe approach?",
            corrected: "The approach you have given is this safe approach."))
    }

    /// One character out of sixty, so every other gate waves it through.
    func testTheOlderGatesDoNotCatchIt() {
        let asked = "The approach A which you have given, is this safe approach?"
        let told = "The approach you have given is this safe approach."
        XCTAssertTrue(checker.isTrustworthy(original: asked, corrected: told),
                      "similarity cannot see a question mark")
    }

    func testTrailingSpaceDoesNotHideIt() {
        XCTAssertTrue(checker.flipsQuestion(
            original: "is this safe?  ", corrected: "  This is safe."))
    }

    // MARK: - What must still get through

    func testAQuestionThatStaysAQuestionIsFine() {
        XCTAssertFalse(checker.flipsQuestion(
            original: "is this safe aproach?", corrected: "Is this a safe approach?"))
    }

    /// Adding the missing question mark is a real correction.
    func testAddingAQuestionMarkIsAllowed() {
        XCTAssertFalse(checker.flipsQuestion(
            original: "is this safe", corrected: "Is this safe?"))
    }

    func testStatementsAreUnaffected() {
        XCTAssertFalse(checker.flipsQuestion(
            original: "this is safe", corrected: "This is safe."))
    }

    func testExclamationIsNotAQuestion() {
        XCTAssertFalse(checker.flipsQuestion(
            original: "this is safe!", corrected: "This is safe."))
    }

    /// A question mark inside the sentence is not what is being protected;
    /// only the one at the end says the whole sentence asks something.
    func testOnlyTheFinalMarkCounts() {
        XCTAssertFalse(checker.flipsQuestion(
            original: "he asked why? and left", corrected: "He asked why and left."))
    }
}
