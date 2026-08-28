import AppKit

/// Traces the inline-underline pipeline end to end and prints each stage.
///
/// The pipeline has five places it can fail silently, and from the outside they
/// all look identical: no squiggles. This names the one that broke.
@MainActor
enum LiveProbe {
    static func run(seconds: Int, engine: HarperEngine) async -> Int32 {
        guard AXAccess.isTrusted else {
            print("FAIL [permission]: not trusted for Accessibility.")
            print("  tccutil reset Accessibility com.kushagra.nib")
            return 1
        }
        print("trusted: yes")
        print("watching for \(seconds)s -- click into a text field and type\n")

        var lastReport = ""
        for tick in 0..<(seconds * 2) {
            let report = await snapshot(engine: engine)
            if report != lastReport {
                print("[\(String(format: "%5.1f", Double(tick) / 2))s] \(report)")
                lastReport = report
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return 0
    }

    private static func snapshot(engine: HarperEngine) async -> String {
        // 1. Is there a focused element at all?
        guard let element = AXElement.focused else {
            let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
            return "no focused element (frontmost: \(app))"
        }

        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let role = element.role ?? "?"

        // 2. Is it a role we underline?
        let editable: Set<String> = [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole]
        guard editable.contains(role) else {
            return "\(app): role \(role) is not an editable text role -- skipped"
        }

        // 3. Can we read the text?
        guard let text = element.string(for: kAXValueAttribute), !text.isEmpty else {
            return "\(app) [\(role)]: focused, but no readable text"
        }

        // 4. Does the field report its own frame?
        guard let frame = AXGeometry.frame(of: element) else {
            return "\(app) [\(role)]: \(text.count) chars, but NO frame -- cannot place overlay"
        }

        // 5. Does harper find anything?
        guard let found = try? await engine.lint(text), !found.isEmpty else {
            return "\(app) [\(role)]: \(text.count) chars, frame ok, 0 issues found"
        }

        // 6. Does AX report bounds for those ranges? This is the step that
        //    decides whether inline underlines are possible at all.
        let marks = AXGeometry.rects(for: found, in: element)
        guard !marks.isEmpty else {
            return "\(app) [\(role)]: \(found.count) issues, but NO bounds for any range "
                + "-- this app cannot show inline underlines"
        }

        let visible = marks.filter { frame.intersects($0.rect) }
        let first = marks[0].rect
        return "\(app) [\(role)]: \(found.count) issues, \(marks.count) with bounds, "
            + "\(visible.count) inside frame | field \(short(frame)) "
            + "first mark \(short(first))"
            + (visible.isEmpty ? "  <-- marks fall OUTSIDE the field, coordinates are wrong" : "")
    }

    private static func short(_ r: CGRect) -> String {
        "(\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height)))"
    }
}
