import AppKit
import ApplicationServices

/// Reports what the Accessibility API exposes for the currently focused text
/// field. This is the measurement the inline-underline plan depends on: a field
/// that will not report bounds for a character range cannot be underlined in
/// place by anyone, Harper and Grammarly included.
enum AXProbe {
    struct Report {
        var app: String
        var role: String
        var canReadValue: Bool
        var valueLength: Int
        var canReadSelection: Bool
        var valueSettable: Bool
        var selectionSettable: Bool
        var boundsForRange: CGRect?
        /// Whether a multi-character range answers, not just one character.
        var boundsForWord: Bool
        var attributes: [String]

        /// Panel-only, in-place edits, or full inline underlines.
        var verdict: String {
            if boundsForWord && (valueSettable || selectionSettable) {
                return "inline underlines possible"
            }
            if boundsForRange != nil {
                return "panel only — reports text bounds but not for a word"
            }
            if valueSettable || selectionSettable {
                return "panel + in-place replace (no inline underlines)"
            }
            if canReadValue || canReadSelection {
                return "panel, read-only via AX (writes need paste fallback)"
            }
            return "clipboard fallback only"
        }
    }

    /// Explains why no text element could be reached, rather than just failing.
    static func diagnoseNoFocus() -> String {
        ChromiumAccessibility.enableForFrontmost()
        guard let running = NSWorkspace.shared.frontmostApplication else {
            return "No frontmost application at all."
        }
        let name = running.localizedName ?? "unknown"
        let appElement = AXElement.application(pid: running.processIdentifier)

        let (_, focusErr) = appElement.read(kAXFocusedUIElementAttribute)
        let attributes = appElement.attributeNames

        if attributes.isEmpty {
            return """
            Frontmost app: \(name)
            It exposes no accessibility attributes at all (error \(focusErr.rawValue)).
            Either the app has no accessibility support, or nib is not trusted.
            """
        }
        return """
        Frontmost app: \(name)
        App element reachable, but it reports no focused UI element
        (error \(focusErr.rawValue)).
        Usually means focus is not in a text field, or the app draws its own
        text without exposing it. App-level attributes present: \(attributes.count).
        """
    }

    static func probeFocused() -> Report? {
        ChromiumAccessibility.enableForFrontmost()
        guard let element = AXElement.focused else { return nil }

        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
        let value = element.string(for: kAXValueAttribute)
        let selection = element.string(for: kAXSelectedTextAttribute)

        // Two probes, because they are different questions. Slack answers for
        // a single character and returns nothing for a word, so asking only
        // the easy one reported it as fully capable while every mark was
        // being dropped.
        let length = value?.utf16.count ?? 0
        let single = length > 0 ? element.bounds(forRange: CFRange(location: 0, length: 1)) : nil
        let word = length >= 4
            ? element.bounds(forRange: CFRange(location: 0, length: 4))
            : nil
        let bounds = word ?? single

        return Report(
            app: app,
            role: element.role ?? "unknown",
            canReadValue: value != nil,
            valueLength: value?.utf16.count ?? 0,
            canReadSelection: selection != nil,
            valueSettable: element.isSettable(kAXValueAttribute),
            selectionSettable: element.isSettable(kAXSelectedTextAttribute),
            boundsForRange: bounds,
            boundsForWord: word != nil,
            attributes: element.attributeNames
        )
    }

    static func printReport(_ r: Report) {
        print("""
          app:              \(r.app)
          role:             \(r.role)
          read value:       \(r.canReadValue ? "yes (\(r.valueLength) chars)" : "no")
          read selection:   \(r.canReadSelection ? "yes" : "no")
          write value:      \(r.valueSettable ? "yes" : "no")
          write selection:  \(r.selectionSettable ? "yes" : "no")
          bounds, 1 char:   \(r.boundsForRange == nil ? "NO" : "yes")
          bounds, 4 chars:  \(r.boundsForWord ? "yes" : "NO — needs per-character fallback")
          verdict:          \(r.verdict)
        """)
    }
}
