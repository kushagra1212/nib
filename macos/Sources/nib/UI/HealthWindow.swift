import AppKit

/// The old Status… window, now a host for `StatusSection`.
///
/// The cards, and every reason they read the way they do, moved to
/// StatusSection so the control panel can show the same thing. What is left
/// here is the window: where it opens, and the ordering dance an accessory app
/// needs to make a window appear at all.
///
/// Kept during the transition so Status… keeps working while the control panel
/// is built. It goes when the menu item does.
@MainActor
final class HealthWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let section = StatusSection()

    /// Supplied by AppDelegate, which owns the engines this reads the state of.
    var context: @MainActor () -> HealthContext = { .empty() } {
        didSet { section.context = context }
    }
    /// Restart one feature. Returns a line to show, or nil to stay quiet.
    var onRestart: (@MainActor (Feature) -> String?)? {
        didSet { section.onRestart = onRestart }
    }
    /// Restart the whole app.
    var onRestartApp: (@MainActor () -> Void)? {
        didSet { section.onRestartApp = onRestartApp }
    }
    /// Open the window that fixes a missing download.
    var onFix: (@MainActor (Feature) -> Void)? {
        didSet { section.onFix = onFix }
    }

    func show() {
        if let window {
            section.refresh()
            place(window)
            raise(window)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "nib Status"
        window.delegate = self
        window.isReleasedWhenClosed = false

        window.contentView = ScrollingPane.make(
            content: section.makeView(), size: NSSize(width: 520, height: 560))
        self.window = window

        place(window)
        raise(window)
        // Logged so "nothing happened" can be told apart from "the action never
        // ran", which is exactly the pair that had to be guessed between when
        // the window was built and then never ordered in.
        Log.write("status panel opened")
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        section.clearNote()
        return true
    }

    func refresh() {
        guard window != nil else { return }
        section.refresh()
    }

    /// On the screen the pointer is on, slightly above centre.
    ///
    /// Not `window.center()`: this opens from a menu bar item, which may be on
    /// a second display, and centring puts it on the main one instead.
    private func place(_ window: NSWindow) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                      y: visible.midY - size.height / 2
                                        + visible.height * 0.08))
    }

    /// `orderFrontRegardless` is the load-bearing line, and leaving it out is
    /// what made Status… do nothing at all. nib is a menu bar accessory, and an
    /// accessory app that is not frontmost does not get its window ordered in
    /// by `makeKeyAndOrderFront` alone -- the window is created, the action
    /// runs, and nothing appears.
    private func raise(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}
