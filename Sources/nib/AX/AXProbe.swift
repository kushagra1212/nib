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
        var attributes: [String]

        /// Panel-only, in-place edits, or full inline underlines.
        var verdict: String {
            if boundsForRange != nil && (valueSettable || selectionSettable) {
                return "inline underlines possible"
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
        guard let element = AXElement.focused else { return nil }

        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
        let value = element.string(for: kAXValueAttribute)
        let selection = element.string(for: kAXSelectedTextAttribute)

        // Probe bounds over the first character, which every text field has if
        // it supports the attribute at all.
        let probeRange = CFRange(location: 0, length: min(1, (value?.utf16.count ?? 0)))
        let bounds = probeRange.length > 0 ? element.bounds(forRange: probeRange) : nil

        return Report(
            app: app,
            role: element.role ?? "unknown",
            canReadValue: value != nil,
            valueLength: value?.utf16.count ?? 0,
            canReadSelection: selection != nil,
            valueSettable: element.isSettable(kAXValueAttribute),
            selectionSettable: element.isSettable(kAXSelectedTextAttribute),
            boundsForRange: bounds,
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
          bounds for range: \(r.boundsForRange.map { "yes \($0)" } ?? "NO")
          verdict:          \(r.verdict)
        """)
    }
}
