import AppKit

/// nib's one window.
///
/// Everything nib knows used to be spread across twenty menu items, and the
/// window that already held most of it sat behind an item called "Status…"
/// that a daily user had not found. A menu is a fine place for five verbs and
/// a poor place for a control panel.
///
/// The layout is deliberately the same shape as HealthWindow's, which works.
/// The first version of this wrapped the scroll view in a container so a
/// sidebar could sit beside it, and called setContentSize afterwards to force
/// a width. The window came out **zero pixels wide** -- `size = (0, 648)` --
/// and place() then centred that nothing onto a second display at x -1304, so
/// nib looked like it was doing nothing at all while reporting that it had
/// opened a panel.
///
/// The sidebar arrives with the second section, built on a layout that has
/// been seen to work rather than one invented alongside it.
@MainActor
final class ControlPanelWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    /// The Status pane. Owned here, configured by AppDelegate.
    let status = StatusSection()

    func show() {
        if let window {
            status.refresh()
            place(window)
            raise(window)
            return
        }

        // Before the window exists, not after it is on screen.
        //
        // setActivationPolicy makes AppKit recompute window frames. Called
        // after this window was built and placed, it collapsed it to zero
        // pixels wide -- measured at `size = (0, 648)`, sitting off-screen on
        // the second display -- so nib reported "control panel opened" with
        // nothing to see.
        ActivationPolicy.windowOpened()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "nib"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 460, height: 360)

        window.contentView = ScrollingPane.make(
            content: status.makeView(), size: NSSize(width: 560, height: 620))
        self.window = window

        place(window)
        raise(window)
        Log.write("control panel opened")
    }

    func windowWillClose(_ notification: Notification) {
        status.clearNote()
        ActivationPolicy.windowClosed()
    }

    /// On the screen the pointer is on, slightly above centre.
    ///
    /// Not `window.center()`: this can open from a menu bar item on a second
    /// display, and centring puts it on the main one instead.
    private func place(_ window: NSWindow) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                      y: visible.midY - size.height / 2
                                        + visible.height * 0.06))
    }

    /// `orderFrontRegardless` is load-bearing. nib may still be an accessory
    /// app at this point -- the policy switch and this call race -- and an
    /// accessory app that is not frontmost does not get its window ordered in
    /// by `makeKeyAndOrderFront` alone. Leaving it out is what made the old
    /// Status… item appear to do nothing.
    private func raise(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}
