import AppKit
import XCTest
@testable import nib

/// The bug this exists for shipped twice before anything caught it.
///
/// The control panel opened at `size = (0, 648)` -- zero pixels wide, on
/// whichever display the pointer was on. Nothing failed: the app launched, the
/// menu item worked, and the log recorded that the panel had opened. Only
/// measuring the window found it.
///
/// The cause is a constraint-driven window meeting `setActivationPolicy`.
/// Pinning the scroll view to the content view lets Auto Layout size the
/// window, and switching an accessory app to regular makes AppKit recompute
/// that size -- with nothing to recompute back to, because an NSScrollView has
/// no intrinsic width and the document tracks the scroll view rather than the
/// content. Either half alone is harmless, which is what made it hard to see.
@MainActor
final class ScrollingPaneTests: XCTestCase {
    /// A pane full of wrapping text, which is what the real cards are and what
    /// makes the intrinsic width too small to save the layout.
    private func makeCards() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        for _ in 0..<6 {
            let field = NSTextField(wrappingLabelWithString:
                "Underlining mistakes while you type, and a sentence long "
                + "enough to need wrapping at the pane's width.")
            field.preferredMaxLayoutWidth = 460
            stack.addArrangedSubview(field)
        }
        return stack
    }

    private func window(containing content: NSView) -> NSWindow {
        let size = NSSize(width: 560, height: 620)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = content
        window.layoutIfNeeded()
        return window
    }

    func testThePaneKeepsTheWidthItsWindowWasGiven() {
        let pane = ScrollingPane.make(content: makeCards(),
                                      size: NSSize(width: 560, height: 620))
        let window = self.window(containing: pane)

        XCTAssertEqual(window.contentView?.frame.width, 560,
                       "the window should keep the width it was created with")
        XCTAssertEqual(window.contentView?.frame.height, 620)
    }

    func testThePaneSurvivesBeingResized() {
        let pane = ScrollingPane.make(content: makeCards(),
                                      size: NSSize(width: 560, height: 620))
        let window = self.window(containing: pane)

        window.setContentSize(NSSize(width: 700, height: 500))
        window.layoutIfNeeded()

        XCTAssertEqual(window.contentView?.frame.width, 700)
        XCTAssertEqual(window.contentView?.frame.height, 500)
    }

    /// Deliberately absent: a test asserting the old arrangement collapses.
    ///
    /// It does not, in isolation. Built into a plain NSWindow here it holds 560
    /// exactly, and an earlier version of this file asserted otherwise and
    /// failed. The collapse needs `setActivationPolicy` as well -- switching an
    /// accessory app to regular makes AppKit recompute the frame, and only the
    /// constraint-driven arrangement loses its width to that. Reproducing it
    /// would mean changing the test runner's own activation policy, which is
    /// worse than leaving the case to the tests above.
    ///
    /// And the arrangement that replaced it does have a width to give.
    func testTheNewArrangementHasAWidth() {
        let pane = ScrollingPane.make(content: makeCards(),
                                      size: NSSize(width: 560, height: 620))
        XCTAssertEqual(pane.frame.width, 560)
    }
}
