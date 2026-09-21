import AppKit

/// Whether nib appears in the Dock.
///
/// nib is a menu-bar tool and spends almost all its life as `.accessory`: no
/// Dock icon, no ⌘-Tab, no app menu. That stops being right the moment it owns
/// a window. An accessory app's windows cannot be reached with ⌘-Tab, so one
/// that slips behind Safari can only be recovered through the menu bar -- and
/// someone who has just been told "open nib to see what is broken" is not in a
/// mood to hunt for it.
///
/// So the policy follows the windows: regular while any is open, accessory
/// again when the last one closes.
@MainActor
enum ActivationPolicy {
    /// The decision, separated from applying it so it can be tested without
    /// an NSApplication.
    nonisolated static func desired(openWindows: Int) -> NSApplication.ActivationPolicy {
        openWindows > 0 ? .regular : .accessory
    }

    /// How many nib windows are currently on screen.
    private static var openWindows = 0

    static func windowOpened() {
        openWindows += 1
        apply()
    }

    static func windowClosed() {
        // Clamped rather than allowed to go negative. An unbalanced close would
        // otherwise leave nib one window short of ever showing a Dock icon
        // again -- a bug nobody would think to connect to this file.
        openWindows = max(0, openWindows - 1)
        apply()
    }

    private static func apply() {
        let policy = desired(openWindows: openWindows)
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if policy == .regular {
            NSApp.activate(ignoringOtherApps: true)
        }
        Log.write("activation policy now \(policy == .regular ? "regular" : "accessory")")
    }
}
