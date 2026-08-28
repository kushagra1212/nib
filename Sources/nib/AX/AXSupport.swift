import AppKit
import ApplicationServices
import Foundation

enum AXAccess {
    /// Whether this process is allowed to drive other apps.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Prompts for Accessibility permission. macOS shows the dialog once per
    /// app identity; afterwards the user must toggle it in System Settings.
    @discardableResult
    static func requestTrust() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func openSettings() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

/// Thin typed wrapper over the AXUIElement C API.
struct AXElement {
    let raw: AXUIElement

    static var systemWide: AXElement { AXElement(raw: AXUIElementCreateSystemWide()) }

    static func application(pid: pid_t) -> AXElement {
        AXElement(raw: AXUIElementCreateApplication(pid))
    }

    /// The element with keyboard focus.
    ///
    /// Asking the system-wide element for its focused element is documented but
    /// unreliable in practice: it returns nothing for many apps. Going through
    /// the frontmost application's own element works far more often, so that is
    /// tried first and the system-wide call is only a fallback.
    static var focused: AXElement? {
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let element = application(pid: pid).element(for: kAXFocusedUIElementAttribute) {
            return element
        }
        return systemWide.element(for: kAXFocusedUIElementAttribute)
    }

    /// Reads an attribute, returning the raw AXError alongside the value so
    /// callers can tell "unsupported" apart from "permission denied".
    func read(_ attribute: String) -> (value: AnyObject?, error: AXError) {
        var out: AnyObject?
        let err = AXUIElementCopyAttributeValue(raw, attribute as CFString, &out)
        return (err == .success ? out : nil, err)
    }

    func value(for attribute: String) -> AnyObject? {
        read(attribute).value
    }

    func string(for attribute: String) -> String? {
        value(for: attribute) as? String
    }

    func element(for attribute: String) -> AXElement? {
        guard let out = value(for: attribute) else { return nil }
        guard CFGetTypeID(out) == AXUIElementGetTypeID() else { return nil }
        return AXElement(raw: out as! AXUIElement)
    }

    func range(for attribute: String) -> CFRange? {
        guard let out = value(for: attribute) else { return nil }
        guard CFGetTypeID(out) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(out as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    @discardableResult
    func set(_ attribute: String, to value: AnyObject) -> Bool {
        AXUIElementSetAttributeValue(raw, attribute as CFString, value) == .success
    }

    func isSettable(_ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        let err = AXUIElementIsAttributeSettable(raw, attribute as CFString, &settable)
        return err == .success && settable.boolValue
    }

    var attributeNames: [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(raw, &names) == .success,
              let list = names as? [String] else { return [] }
        return list
    }

    var role: String? { string(for: kAXRoleAttribute) }

    /// Screen rect for a character range.
    ///
    /// This is the attribute inline underlines depend on. Native AppKit text
    /// views implement it; most Electron and browser text fields do not, which
    /// is why drawing squiggles over the real text cannot work everywhere.
    func bounds(forRange range: CFRange) -> CGRect? {
        guard let rect = rawBounds(forRange: range) else { return nil }
        guard AXElement.isDrawable(rect) else { return nil }
        return rect
    }

    /// The rectangle exactly as the app reported it, degenerate or not.
    ///
    /// Only the diagnostic uses this. Everything else wants `bounds(forRange:)`,
    /// which rejects rectangles that cannot be drawn on. Keeping the unfiltered
    /// answer reachable is what makes "nil" legible in a bug report: an app that
    /// declines to answer and an app that answers `0x0` look identical
    /// otherwise, and telling them apart took five rounds once already.
    func rawBounds(forRange range: CFRange) -> CGRect? {
        var input = range
        guard let axRange = AXValueCreate(.cfRange, &input) else { return nil }
        var out: AnyObject?
        let err = AXUIElementCopyParameterizedAttributeValue(
            raw,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            axRange,
            &out
        )
        guard err == .success, let out,
              CFGetTypeID(out) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(out as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    /// Whether a reported rectangle is somewhere a mark could actually go.
    ///
    /// Chromium answers the bounds attribute for text it has not laid out and
    /// returns a zero-sized rectangle -- Slack returns `0,982 0x0` for every
    /// range in the message box. Counting that as a real answer is what let the
    /// probe call Slack fully capable while every mark was dropped further
    /// down, and cost five rounds of looking in the wrong place.
    static func isDrawable(_ rect: CGRect) -> Bool {
        // `isNull` and `isInfinite` are checked by name rather than by
        // measuring: CGRect.infinite is built from CGFloat.greatestFiniteMagnitude,
        // so every component of it passes an `isFinite` test.
        guard !rect.isNull, !rect.isInfinite, !rect.isEmpty else { return false }
        // `rect.size` rather than `rect.width`, which standardises a negative
        // width into a positive one and hides the bad answer.
        guard rect.size.width > 0, rect.size.height > 0 else { return false }
        guard rect.size.width.isFinite, rect.size.height.isFinite else { return false }
        guard rect.origin.x.isFinite, rect.origin.y.isFinite else { return false }
        return true
    }
}
