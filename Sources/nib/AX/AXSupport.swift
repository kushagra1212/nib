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

    /// What the user has typed, with placeholder text treated as nothing.
    ///
    /// An empty Chromium field reports its placeholder as its value, so nib
    /// read "Ask anything" out of an empty ChatGPT box, linted it, and offered
    /// to put a full stop on the end of it. Worse than the wrong suggestion:
    /// the field looked busy, so nothing that mattered was ever checked.
    var editableText: String {
        let value = string(for: kAXValueAttribute) ?? ""
        guard !value.isEmpty else { return "" }
        let placeholders = [
            string(for: kAXPlaceholderValueAttribute),
            // Chromium puts the placeholder here for a contenteditable div,
            // which is what most chat composers are.
            string(for: kAXDescriptionAttribute),
        ]
        return AXElement.isPlaceholder(value: value, anyOf: placeholders) ? "" : value
    }

    /// Whether a field's value is only its own placeholder showing through.
    ///
    /// Exact match after trimming, deliberately. Someone who genuinely types
    /// the placeholder word for word gets ignored, which costs one suggestion;
    /// anything looser would start discarding real text that happens to begin
    /// the same way.
    static func isPlaceholder(value: String, anyOf placeholders: [String?]) -> Bool {
        let typed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return true }
        return placeholders.contains { candidate in
            guard let candidate else { return false }
            let hint = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            return !hint.isEmpty && hint == typed
        }
    }

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

    // MARK: - Text markers

    /// Chromium's answer to "where is this text".
    ///
    /// A text marker is an opaque position in a document, with no public
    /// header and no way to construct one -- they only ever come back from the
    /// app. Chromium implements these for VoiceOver and answers them properly
    /// while returning an empty rectangle for the documented
    /// `AXBoundsForRange`, so this is the only route to a rectangle in Slack,
    /// ChatGPT, Chrome, and every other Electron app.
    ///
    /// Everything here is addressed by attribute name and passes the values
    /// straight back and forth without inspecting them, so no private symbols
    /// are needed.
    private func parameterized(_ attribute: String, _ parameter: AnyObject) -> AnyObject? {
        var out: AnyObject?
        let err = AXUIElementCopyParameterizedAttributeValue(
            raw, attribute as CFString, parameter, &out)
        return err == .success ? out : nil
    }

    /// The screen rectangle of the element itself.
    var frame: CGRect? {
        // "AXFrame" has no constant in the Swift overlay.
        guard let out = value(for: "AXFrame"),
              CFGetTypeID(out) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(out as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    /// The first marker inside a rectangle. This is how a walk gets started:
    /// markers cannot be constructed, only asked for.
    func startMarker(forBounds bounds: CGRect) -> AnyObject? {
        var rect = bounds
        guard let value = AXValueCreate(.cgRect, &rect) else { return nil }
        return parameterized("AXStartTextMarkerForBounds", value)
    }

    /// The marker at a screen point, which is also how hover hit-testing
    /// works: pointer position in, position in the text out.
    func marker(atPosition point: CGPoint) -> AnyObject? {
        var position = point
        guard let value = AXValueCreate(.cgPoint, &position) else { return nil }
        return parameterized("AXTextMarkerForPosition", value)
    }

    func marker(after marker: AnyObject) -> AnyObject? {
        parameterized("AXNextTextMarkerForTextMarker", marker)
    }

    /// Builds a range from two markers. "Unordered" because the attribute
    /// sorts them itself, so the caller need not know which comes first.
    func markerRange(from start: AnyObject, to end: AnyObject) -> AnyObject? {
        parameterized("AXTextMarkerRangeForUnorderedTextMarkers",
                      [start, end] as CFArray)
    }

    func bounds(forMarkerRange range: AnyObject) -> CGRect? {
        guard let out = parameterized("AXBoundsForTextMarkerRange", range),
              CFGetTypeID(out) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(out as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    /// The text a marker range covers, so a rectangle can be checked against
    /// the word it is supposed to be under.
    func string(forMarkerRange range: AnyObject) -> String? {
        parameterized("AXStringForTextMarkerRange", range) as? String
    }

    /// A marker range covering the whole element.
    func wholeMarkerRange() -> AnyObject? {
        parameterized("AXTextMarkerRangeForUIElement", raw)
    }

    /// The character range of one visual line, addressed by line number.
    ///
    /// If this answers for a contenteditable, nib knows where the app decided
    /// to wrap even though it will not say where the words are.
    func range(forLine line: Int) -> CFRange? {
        guard let out = parameterized("AXRangeForLine", line as CFNumber),
              CFGetTypeID(out) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(out as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    /// The text of a range with its styling, which is where the font would
    /// come from if nib had to lay the text out itself.
    func attributedString(forRange range: CFRange) -> NSAttributedString? {
        var input = range
        guard let axRange = AXValueCreate(.cfRange, &input) else { return nil }
        return parameterized("AXAttributedStringForRange", axRange) as? NSAttributedString
    }

    /// A marker range for one visual line, addressed by number.
    ///
    /// The only range this app hands out that needs no marker to ask for.
    func markerRange(forLine line: Int) -> AnyObject? {
        parameterized("AXTextMarkerRangeForLine", line as CFNumber)
    }

    /// Hops `offset` markers forward from `start`, then `length` further, and
    /// builds a range between the two positions.
    ///
    /// One cross-process call per character. Fine over a line, far too slow
    /// over a long document, which is why callers walk in ascending order and
    /// keep the marker they reached.
    func markerSpan(from start: AnyObject, offset: Int, length: Int) -> AnyObject? {
        var cursor = start
        for _ in 0..<offset {
            guard let next = marker(after: cursor) else { return nil }
            cursor = next
        }
        var end = cursor
        for _ in 0..<length {
            guard let next = marker(after: end) else { break }
            end = next
        }
        return markerRange(from: cursor, to: end)
            ?? TextMarkerBridge.range(from: cursor, to: end)
    }

    /// Asks for the element's whole text as a marker range, then for the
    /// rectangle covering it.
    ///
    /// Chromium answers `AXBoundsForRange` with an empty rectangle but reports
    /// real geometry to VoiceOver through text markers, which are an opaque
    /// Apple type with no public header. The attributes are addressed by name.
    /// A non-empty rectangle here means Slack and every other Electron app can
    /// be underlined after all, just not through the documented attribute.
    func markerBounds() -> CGRect? {
        var markerRange: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            raw, "AXTextMarkerRangeForUIElement" as CFString, raw, &markerRange
        ) == .success, let markerRange else { return nil }

        var out: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(
            raw, "AXBoundsForTextMarkerRange" as CFString, markerRange, &out
        ) == .success, let out, CFGetTypeID(out) == AXValueGetTypeID() else { return nil }

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
