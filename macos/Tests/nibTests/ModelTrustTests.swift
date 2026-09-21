import XCTest
@testable import nib

/// Covers the guard that decides whether a model's rewrite is a correction or
/// something else entirely. Without it, a small model that answers the text
/// rather than correcting it would have its answer applied as inline "fixes",
/// silently replacing what the user wrote.
final class ModelTrustTests: XCTestCase {
    private var checker: ModelChecker!

    override func setUp() async throws {
        // Only the pure judgement is exercised; no server is started.
        let config = RewriteEngine.Config(
            serverBinary: URL(fileURLWithPath: "/nonexistent"),
            modelPath: URL(fileURLWithPath: "/nonexistent")
        )
        checker = ModelChecker(rewriter: RewriteEngine(config: config))
    }

    private func trusts(_ original: String, _ corrected: String) -> Bool {
        checker.isTrustworthy(original: original, corrected: corrected)
    }

    func testIdenticalTextIsTrusted() {
        let text = "Nothing to fix here."
        XCTAssertTrue(trusts(text, text))
    }

    func testSmallCorrectionIsTrusted() {
        XCTAssertTrue(trusts("Their is many erors here",
                                   "There are many errors here"))
    }

    func testSingleWordFixIsTrusted() {
        XCTAssertTrue(trusts("it could of worked", "it could have worked"))
    }

    func testTechnicalTextLeftIntactIsTrusted() {
        let text = "UTF-16 traps with NSString.length and ZWJ sequences"
        XCTAssertTrue(trusts(text, text))
    }

    func testSummaryIsRejected() {
        // The failure seen from Gemma 270M: it described the sentence instead
        // of correcting it.
        XCTAssertFalse(trusts(
            "Their is many erors in this sentance, and it are very long and wordy",
            "The sentence is too long and wordy."))
    }

    func testAnsweringTheTextIsRejected() {
        XCTAssertFalse(trusts(
            "What does this mean for the RN 86 upgrade and the tests",
            "It means you will test all the apps on both iOS and Android devices."))
    }

    func testWholesalePaddingIsRejected() {
        XCTAssertFalse(trusts(
            "Fix this",
            "Certainly! Here is the corrected version of the text you provided to me today."))
    }

    func testTruncationIsRejected() {
        XCTAssertFalse(trusts(
            "Their is many erors in this sentance and it are very long and wordy indeed",
            "There are errors."))
    }

    func testEmptyRewriteIsRejected() {
        XCTAssertFalse(trusts("Some real text here", ""))
    }

    func testEmptyOriginalIsRejected() {
        XCTAssertFalse(trusts("", "Some output"))
    }

    func testCompletelyDifferentTextIsRejected() {
        XCTAssertFalse(trusts("the cat sat on the mat",
                                    "dogs run through open fields"))
    }

    func testStyleRewriteIsRejectedForInlineUse() {
        // Grammarly's own example: "I think we should be able to" becoming "We
        // can". A good suggestion, but a restructuring rather than a
        // correction, and the inline path must not silently reshape sentences.
        // Rewrites of this size belong behind the explicit Fix and Clearer
        // buttons, which carry no trust gate because the user asked for them.
        XCTAssertFalse(trusts("we should be able to solve this issue",
                              "we can solve this issue for you"))
    }

    func testMinorRewordingIsTrusted() {
        XCTAssertTrue(trusts("the report was wrote by him",
                             "the report was written by him"))
    }

    func testCaseOnlyChangeIsTrusted() {
        XCTAssertTrue(trusts("the cat sat", "The cat sat"))
    }
}
