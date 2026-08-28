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

    /// The element with keyboard focus, anywhere on the system.
    static var focused: AXElement? {
        systemWide.element(for: kAXFocusedUIElementAttribute)
    }

    func value(for attribute: String) -> AnyObject? {
        var out: AnyObject?
        let err = AXUIElementCopyAttributeValue(raw, attribute as CFString, &out)
        return err == .success ? out : nil
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
}
