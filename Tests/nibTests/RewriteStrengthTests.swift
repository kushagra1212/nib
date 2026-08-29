import XCTest
@testable import nib

/// The dial that says how far a rewrite may travel.
///
/// It has two halves. One asks the model to change more or less, which a 0.6B
/// model ignores -- all three settings returned the same sentence, verbatim.
/// The other decides how much deletion nib will tolerate before refusing the
/// answer, and that half works regardless of which model produced it.
final class RewriteStrengthTests: XCTestCase {
    private var checker: ModelChecker!

    override func setUp() async throws {
        let config = RewriteEngine.Config(
            serverBinary: URL(fileURLWithPath: "/nonexistent"),
            modelPath: URL(fileURLWithPath: "/nonexistent")
        )
        checker = ModelChecker(rewriter: RewriteEngine(config: config))
    }

    // MARK: - What each stop allows

    func testLightRefusesTwoMissingWords() {
        XCTAssertEqual(RewriteStrength.light.maxDroppedRun, 2)
        XCTAssertTrue(checker.dropsContent(
            original: "keep one two three four",
            corrected: "keep three four",
            limit: RewriteStrength.light.maxDroppedRun!))
    }

    func testBalancedAllowsTwoAndRefusesThree() {
        let limit = RewriteStrength.balanced.maxDroppedRun!
        XCTAssertEqual(limit, 3)
        XCTAssertFalse(checker.dropsContent(
            original: "keep one two three four",
            corrected: "keep three four", limit: limit))
        XCTAssertTrue(checker.dropsContent(
            original: "keep one two three four",
            corrected: "keep four", limit: limit))
    }

    /// Bold turns the check off. The reader is shown the whole rewrite and
    /// nothing is applied until they accept it, which is the safeguard at that
    /// setting.
    func testBoldHasNoLimit() {
        XCTAssertNil(RewriteStrength.bold.maxDroppedRun)
    }

    /// The reported deletion -- "product details 3 options" off the end of a
    /// Slack message -- is refused at both of the settings that check.
    func testTheReportedDeletionIsRefusedBelowBold() {
        let typed = "can also scroll to top of the catalog so that after "
            + "navigation product can be shown directly instead user has to "
            + "scroll to top to see the product that they click on product "
            + "details 3 options"
        let returned = "Can also scroll to the top of the catalog so that after "
            + "navigation, product details can be shown directly instead of the "
            + "user having to scroll to the top to see the product that they "
            + "click on."
        for strength in [RewriteStrength.light, .balanced] {
            XCTAssertTrue(
                checker.dropsContent(original: typed, corrected: returned,
                                     limit: strength.maxDroppedRun!),
                "\(strength.rawValue) must refuse a four-word deletion")
        }
    }

    // MARK: - Which modes the dial applies to

    /// Only Fix is held to the mid-sentence deletion rule.
    ///
    /// Clearer was on the strict side of this line and should not have been.
    /// Cutting "probably think about maybe" to "consider" is four words gone
    /// in a row, and refusing that refuses the edit Clearer exists to make.
    func testModesAskedToRestructureAreExempt() {
        XCTAssertTrue(RewriteMode.clearer.mayRestructure)
        XCTAssertTrue(RewriteMode.shorter.mayRestructure)
        XCTAssertTrue(RewriteMode.freely.mayRestructure)
        XCTAssertFalse(RewriteMode.fixGrammar.mayRestructure)
    }

    /// Exempt from the middle rule, never from the ending one.
    func testATruncatedEndingIsRefusedInEveryMode() {
        let typed = "add the check to the cart page before the release goes out"
        let cut = "add the check to the cart page"
        XCTAssertGreaterThanOrEqual(
            checker.droppedTail(original: typed, corrected: cut), 3)
    }

    func testTighteningTheMiddleIsNotATruncation() {
        let typed = "we should probably think about maybe adding a check at some point"
        let tightened = "We should consider adding a check at some point."
        XCTAssertLessThan(
            checker.droppedTail(original: typed, corrected: tightened), 3,
            "the ending survived, so this is tightening, not truncation")
        XCTAssertGreaterThanOrEqual(
            checker.longestDroppedRun(original: typed, corrected: tightened), 3,
            "and the middle run is exactly what the old rule refused")
    }

    // MARK: - The setting itself

    func testDefaultsToBalanced() {
        XCTAssertEqual(RewriteStrength(rawValue: "nonsense"), nil)
        XCTAssertEqual(RewriteStrength.allCases.count, 3)
    }

    func testEveryStopChangesTheInstruction() {
        let clauses = RewriteStrength.allCases.map(\.clause)
        XCTAssertEqual(Set(clauses).count, clauses.count,
                       "each setting must ask the model for something different")
        XCTAssertTrue(clauses.allSatisfy { !$0.isEmpty })
    }

    func testTheClauseReachesTheSystemPrompt() {
        let light = RewriteMode.freely.systemPrompt(strength: .light)
        let bold = RewriteMode.freely.systemPrompt(strength: .bold)
        XCTAssertTrue(light.contains(RewriteStrength.light.clause))
        XCTAssertTrue(bold.contains(RewriteStrength.bold.clause))
        XCTAssertNotEqual(light, bold)
    }
}
