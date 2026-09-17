import AppKit
import XCTest
@testable import nib

/// Saying which rewrite produced the text on screen.
///
/// Reported as a quality complaint: nib's Native rewrite was compared against
/// ChatGPT's and found weaker. The text being judged was Fix's. The bar runs
/// `autoOrder` and stops at the first mode that changes anything, so Fix
/// answers whenever the grammar is wrong -- and the tag on the proposal said
/// only "AI", which is true of all four modes and identifies none of them.
///
/// Measured on the sentence that was reported, "Then I will test on the APK and
/// event in  the Events Manager.":
///
///     [Fix grammar]    Then I will test the APK and the event in the Events Manager.
///     [Native English] Then I'll test it on the APK and in the Events Manager.
///
/// The two differ, and the quoted complaint matched Fix exactly. So this is not
/// a cosmetic label: without it the reader cannot tell which of nib's rewrites
/// they are judging.
final class ProposalAttributionTests: XCTestCase {

    /// The tag carries the mode's own name.
    func testTheTagNamesTheMode() {
        XCTAssertTrue(Theme.aiTag("Native").string.hasPrefix("NATIVE"))
        XCTAssertTrue(Theme.aiTag("Fix").string.hasPrefix("FIX"))
    }

    /// Inline suggestions have no mode, and keep the generic tag they had.
    func testTheDefaultTagIsUnchanged() {
        XCTAssertTrue(Theme.aiTag().string.hasPrefix("AI"))
    }

    /// A tag only distinguishes modes if the names differ.
    func testEveryModeHasItsOwnName() {
        let names = RewriteMode.allCases.map(\.shortTitle)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertFalse(names.contains(where: \.isEmpty))
    }

    /// Fix runs first, which is why it is nearly always what is on screen.
    ///
    /// Pinned because the ordering is the reason the tag is needed. Reversing
    /// it would make Native the usual answer and would be a change in what nib
    /// does unasked, not a refactor.
    func testTheAutomaticRunIsLeastInvasiveFirst() {
        XCTAssertEqual(SelectionBar.autoOrder, [.fixGrammar, .clearer, .native])
    }

    /// Shorter is not attempted on its own. It drops content by design, which
    /// is never the right thing to do to someone's writing uninvited.
    func testShorteningIsNeverAutomatic() {
        XCTAssertFalse(SelectionBar.autoOrder.contains(.shorter))
    }

    /// The view keeps the mode through a diff, so toggling Diff does not
    /// silently restore the generic tag.
    @MainActor
    func testTheModeSurvivesTheDiffToggle() {
        let view = ProposalView()
        view.writtenBy = "Native"
        view.text = "Then I'll test it on the APK."
        view.show(NSAttributedString(string: "unchanged"))
        XCTAssertEqual(view.writtenBy, "Native")
    }
}
