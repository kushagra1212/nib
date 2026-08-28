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
