import AppKit
import ApplicationServices

/// Asks Chromium-based apps to expose their full accessibility tree.
///
/// Electron and Chrome ship a minimal tree by default and only build the real
/// one when an assistive client asks, because maintaining it costs them
/// noticeable CPU. VoiceOver triggers this automatically; every other client
/// has to set `AXManualAccessibility` on the application element itself.
///
/// Without it, Slack, VS Code, Discord and Chrome report a focused element with
/// no readable text, which looks exactly like an app that has no accessibility
/// support at all.
enum ChromiumAccessibility {
    /// Attribute Chromium watches for. Not in any public header, which is why
    /// it is spelled out rather than referenced from a constant.
    private static let manualAccessibility = "AXManualAccessibility"
    /// Older apps, including some Electron builds, watch this instead.
    private static let enhancedUserInterface = "AXEnhancedUserInterface"

    /// Apps already asked, so a request is made once per launch rather than on
    /// every focus poll.
    private static var enabled: Set<pid_t> = []

    /// Enables the full tree for an app, if it has not been asked already.
    @discardableResult
    static func enable(forProcess pid: pid_t) -> Bool {
        guard !enabled.contains(pid) else { return false }
        enabled.insert(pid)

        let app = AXUIElementCreateApplication(pid)
        // Both are set unconditionally. An app that does not recognise the
        // attribute returns an error, which costs nothing, and there is no way
        // to ask in advance which one a given build honours.
        let manual = AXUIElementSetAttributeValue(
            app, manualAccessibility as CFString, kCFBooleanTrue)
        let enhanced = AXUIElementSetAttributeValue(
            app, enhancedUserInterface as CFString, kCFBooleanTrue)

        return manual == .success || enhanced == .success
    }

    /// Enables the tree for whatever app is frontmost.
    @discardableResult
    static func enableForFrontmost() -> Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        else { return false }
        return enable(forProcess: pid)
    }

    /// Forgets a process so it is asked again, used when an app relaunches.
    static func forget(_ pid: pid_t) {
        enabled.remove(pid)
    }

    static func hasAsked(_ pid: pid_t) -> Bool {
        enabled.contains(pid)
    }
}
