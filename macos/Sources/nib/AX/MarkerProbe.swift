import AppKit
import ApplicationServices

/// Walks a named app's accessibility tree looking for text areas, and reports
/// every way of asking each one where its text sits on screen.
///
/// Written because the question kept needing a human: click into the field,
/// open a menu, copy the output. Focus is not actually required -- an app's
/// element tree can be read from outside -- so this asks directly.
///
/// The question it exists to settle: Chromium answers `AXBoundsForRange` with
/// an empty rectangle, but reports real geometry to VoiceOver through text
/// markers. If markers answer, every Electron app can be underlined properly.
enum MarkerProbe {
    /// Reports on whatever is focused, after a countdown.
    ///
    /// Tree-walking does not reach a browser's web content: Chrome builds
    /// those nodes lazily and a walk from the application element finds only
    /// the omnibox and tab strip. Focus reaches them, which is why nib itself
    /// works on pages that this probe could not see.
    static func runFocused(delay: Int) -> Int32 {
        guard AXAccess.isTrusted else {
            print("nib is not trusted for Accessibility.")
            return 1
        }
        print("Click into the text you want measured.")
        for remaining in stride(from: delay, to: 0, by: -1) {
            print("  measuring in \(remaining)...")
            Thread.sleep(forTimeInterval: 1)
        }

        ChromiumAccessibility.enableForFrontmost()
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"
        guard let element = AXElement.focused else {
            print("app: \(app) -- nothing focused")
            return 1
        }
        print("app: \(app)")
        report(element, index: 0)
        return 0
    }

    static func run(appName: String) -> Int32 {
        guard AXAccess.isTrusted else {
            print("nib is not trusted for Accessibility.")
            print("Run this from the app bundle, and grant it in System Settings:")
            print("  tccutil reset Accessibility com.kushagra.nib")
            return 1
        }

        let matches = NSWorkspace.shared.runningApplications.filter {
            ($0.localizedName ?? "").localizedCaseInsensitiveContains(appName)
        }
        guard let running = matches.first else {
            print("No running app matching \"\(appName)\".")
            let names = NSWorkspace.shared.runningApplications
                .compactMap(\.localizedName).sorted()
            print("Running: \(names.joined(separator: ", "))")
            return 1
        }

        let name = running.localizedName ?? appName
        print("app: \(name) (pid \(running.processIdentifier))")

        // Chromium ships a minimal tree until an assistive client asks for the
        // full one, and it builds that tree asynchronously. Asking and then
        // walking immediately finds nothing.
        ChromiumAccessibility.enable(forProcess: running.processIdentifier)
        Thread.sleep(forTimeInterval: 1.5)

        let app = AXElement.application(pid: running.processIdentifier)
        var found: [AXElement] = []
        var visited = 0
        walk(app, depth: 0, limit: 40, found: &found, visited: &visited)

        guard !found.isEmpty else {
            print("No text areas found. Walked \(visited) elements.")
            return 1
        }

        // Longest first. A browser's tab strip is full of short URL fields
        // that are not web content, and stopping at the first few found meant
        // reporting on the omnibox and calling it a verdict about the page.
        let ranked = found
            .sorted { ($0.string(for: kAXValueAttribute) ?? "").count
                      > ($1.string(for: kAXValueAttribute) ?? "").count }
            .prefix(3)
        print("text elements found: \(found.count) (walked \(visited)),"
              + " reporting the \(ranked.count) longest\n")

        for (index, element) in ranked.enumerated() {
            report(element, index: index)
        }
        return 0
    }

    /// Depth-first, bounded. A Chromium tree is deep and wide enough that an
    /// unbounded walk does not finish in a useful amount of time.
    private static func walk(
        _ element: AXElement,
        depth: Int,
        limit: Int,
        found: inout [AXElement],
        visited: inout Int
    ) {
        guard depth <= limit, found.count < 400, visited < 200_000 else { return }
        visited += 1

        // Chromium's web content uses AXTextArea and AXTextField, but a
        // contenteditable composer -- which is what Slack and ChatGPT both
        // are -- often reports as AXGroup with an editable subrole instead.
        let role = element.role ?? ""
        let subrole = element.string(for: kAXSubroleAttribute) ?? ""
        let editable = role == kAXTextAreaRole || role == kAXTextFieldRole
            || subrole == "AXContentEditable" || subrole == "AXTextArea"
        if editable, !(element.string(for: kAXValueAttribute) ?? "").isEmpty {
            found.append(element)
        }

        guard let children = element.value(for: kAXChildrenAttribute) as? [AXUIElement]
        else { return }
        for child in children {
            walk(AXElement(raw: child), depth: depth + 1, limit: limit,
                 found: &found, visited: &visited)
        }
    }

    private static func report(_ element: AXElement, index: Int) {
        let value = element.string(for: kAXValueAttribute) ?? ""
        let length = value.utf16.count
        print("[\(index)] role: \(element.role ?? "?")  chars: \(length)")
        print("     text: \"\(value.prefix(60))\"")

        let single = element.rawBounds(forRange: CFRange(location: 0, length: 1))
        let word = element.rawBounds(forRange: CFRange(location: 0, length: min(4, length)))
        print("     AXBoundsForRange 1: \(describe(single))")
        print("     AXBoundsForRange 4: \(describe(word))")
        print("     marker bounds:      \(describe(element.markerBounds()))")

        chainTest(element, value: value)
        layoutIngredients(element, value: value)
        positionSweep(element, value: value)
        caretSweep(element, value: value)
        pointerSweep(element, value: value)

        var names: CFArray?
        AXUIElementCopyParameterizedAttributeNames(element.raw, &names)
        let list = (names as? [String]) ?? []
        let markers = list.filter { $0.contains("Marker") }
        print("     param attrs (\(list.count)): \(list.joined(separator: ", "))")
        print("     marker attrs: \(markers.isEmpty ? "none" : markers.joined(separator: ", "))")
        print("")
    }

    /// Walks markers to a word and asks for its rectangle, which is the whole
    /// thing inline underlines need. Prints the text the range covers too: a
    /// rectangle for the wrong word is worse than no rectangle.
    private static func chainTest(_ element: AXElement, value: String) {
        let frame = element.frame
        let markerRect = element.markerBounds()
        print("     frame: \(describe(frame))")

        // Markers cannot be constructed, only obtained, and it is not
        // documented which of these an app will answer. Try each.
        var start: AnyObject?
        var how = ""
        if let frame, let m = element.startMarker(forBounds: frame) {
            start = m; how = "AXStartTextMarkerForBounds(frame)"
        } else if let markerRect, let m = element.startMarker(forBounds: markerRect) {
            start = m; how = "AXStartTextMarkerForBounds(markerBounds)"
        } else if let markerRect,
                  let m = element.marker(atPosition: CGPoint(x: markerRect.minX + 2,
                                                             y: markerRect.minY + 2)) {
            start = m; how = "AXTextMarkerForPosition(topLeft)"
        } else if let frame,
                  let m = element.marker(atPosition: CGPoint(x: frame.minX + 2,
                                                             y: frame.minY + 2)) {
            start = m; how = "AXTextMarkerForPosition(frame topLeft)"
        } else if let whole = element.wholeMarkerRange(),
                  let m = TextMarkerBridge.startMarker(of: whole) {
            start = m; how = "AXTextMarkerRangeCopyStartMarker(wholeRange)"
        }

        guard let start else {
            print("     chain: no way to obtain a first marker")
            return
        }
        print("     first marker via: \(how)")

        // The fifth word in, so the answer is somewhere into the text rather
        // than at the origin, where a wrong implementation still looks right.
        let words = value.split(separator: " ", omittingEmptySubsequences: false)
        guard words.count > 5 else { print("     chain: too few words"); return }
        let offset = words.prefix(5).reduce(0) { $0 + $1.count + 1 }
        let length = words[5].count

        var marker = start
        for _ in 0..<offset {
            guard let next = element.marker(after: marker) else {
                print("     chain: ran out of markers at \(offset)")
                return
            }
            marker = next
        }
        var endMarker = marker
        for _ in 0..<length {
            guard let next = element.marker(after: endMarker) else { break }
            endMarker = next
        }

        let range = element.markerRange(from: marker, to: endMarker)
            ?? TextMarkerBridge.range(from: marker, to: endMarker)
        guard let range else {
            print("     chain: could not build a marker range")
            return
        }
        let text = element.string(forMarkerRange: range) ?? "?"
        let rect = element.bounds(forMarkerRange: range)
        print("     chain: word 5 is \"\(words[5])\", markers gave \"\(text)\"")
        print("     chain bounds:       \(describe(rect))")

        // A rectangle equal to the whole field is not an answer. Ask for
        // several different spans: if they all come back identical, the app
        // resolves the range but not its geometry.
        for target in [0, 3, 9, 14] where target < words.count {
            let offset = words.prefix(target).reduce(0) { $0 + $1.count + 1 }
            guard let span = element.markerSpan(from: start, offset: offset,
                                                length: words[target].count) else {
                continue
            }
            print("     word \(target) \"\(words[target])\" -> "
                  + "\"\(element.string(forMarkerRange: span) ?? "?")\" "
                  + describe(element.bounds(forMarkerRange: span)))
        }

        for line in 0..<3 {
            guard let lineRange = element.markerRange(forLine: line) else { continue }
            let lineText = (element.string(forMarkerRange: lineRange) ?? "").prefix(28)
            print("     line \(line) \"\(lineText)\" "
                  + describe(element.bounds(forMarkerRange: lineRange)))
        }
    }

    /// Whether nib could work out the geometry itself when the app refuses.
    ///
    /// Laying text out needs three things: where the app wrapped each line,
    /// what font it used, and the box to put it in. The first two are asked
    /// for here; the box is already known.
    private static func layoutIngredients(_ element: AXElement, value: String) {
        var lines: [String] = []
        for line in 0..<4 {
            guard let range = element.range(forLine: line) else { break }
            let ns = value as NSString
            let text = NSMaxRange(NSRange(location: range.location, length: range.length))
                <= ns.length
                ? ns.substring(with: NSRange(location: range.location, length: range.length))
                : "<out of bounds>"
            lines.append("line \(line) = \(range.location)+\(range.length) \"\(text.prefix(24))\"")
        }
        print("     line ranges:  \(lines.isEmpty ? "no answer" : lines.joined(separator: "; "))")

        guard let styled = element.attributedString(
            forRange: CFRange(location: 0, length: min(8, value.utf16.count))) else {
            print("     font:         no attributed string")
            return
        }
        let font = styled.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        print("     font:         \(font.map { "\($0.fontName) \($0.pointSize)" } ?? "not reported")")
    }

    /// Asks "which character is under this point" across the field.
    ///
    /// The inverse question to the one every other attribute here refuses.
    /// If it answers, the map can be built the other way round: sample the
    /// box, invert the answers, and the words have positions after all.
    private static func positionSweep(_ element: AXElement, value: String) {
        guard let frame = element.frame, frame.width > 0 else {
            print("     position map: no frame")
            return
        }
        var samples: [String] = []
        let y = frame.minY + min(10, frame.height / 2)
        for step in 0..<6 {
            let x = frame.minX + 4 + CGFloat(step) * (frame.width - 8) / 6
            guard let range = element.range(atPosition: CGPoint(x: x, y: y)) else {
                samples.append("x+\(Int(x - frame.minX))=nil")
                continue
            }
            let ns = value as NSString
            let char = range.location >= 0 && range.location < ns.length
                ? ns.substring(with: NSRange(location: range.location, length: 1))
                : "?"
            samples.append("x+\(Int(x - frame.minX))=\(range.location)'\(char)'")
        }
        print("     position map: \(samples.joined(separator: "  "))")
    }

    /// Whether the caret has a readable rectangle, and whether it moves.
    ///
    /// The caret is geometry an app cannot hide: a screen reader follows it and
    /// an input method has to put its candidate window under it. If it can be
    /// read, every keystroke is one exact sample of "character N is here", and
    /// typing sweeps the line for free.
    private static func caretSweep(_ element: AXElement, value: String) {
        let length = value.utf16.count
        guard length > 8 else { return }

        // Where the caret is now, by every route.
        if let selected = element.range(for: kAXSelectedTextRangeAttribute) {
            print("     caret range:  \(selected.location)+\(selected.length)")
            print("       bounds:     \(describe(element.rawBounds(forRange: selected)))")
        } else {
            print("     caret range:  not reported")
        }
        if let markerRange = element.value(for: "AXSelectedTextMarkerRange") {
            print("       marker sel: \(describe(element.bounds(forMarkerRange: markerRange)))")
        } else {
            print("       marker sel: not reported")
        }

        // Move it, and see whether the rectangle follows.
        guard element.isSettable(kAXSelectedTextRangeAttribute) else {
            print("     caret move:   selection is not settable")
            return
        }
        var moved: [String] = []
        for offset in [0, length / 2, length - 1] {
            var range = CFRange(location: offset, length: 0)
            guard let value = AXValueCreate(.cfRange, &range) else { continue }
            _ = element.set(kAXSelectedTextRangeAttribute, to: value)
            Thread.sleep(forTimeInterval: 0.12)
            let rect = element.rawBounds(forRange: CFRange(location: offset, length: 0))
            let marker = element.value(for: "AXSelectedTextMarkerRange")
                .flatMap { element.bounds(forMarkerRange: $0) }
            moved.append("at \(offset): range=\(describe(rect)) marker=\(describe(marker))")
        }
        print("     caret move:")
        for line in moved { print("       \(line)") }
    }

    /// Which character sits under a given screen point.
    ///
    /// The inverse map, by the one route not yet tried on a contenteditable:
    /// a marker for the point, then the distance from the start marker, which
    /// is the character offset. If this answers, hovering a word is solved
    /// without knowing where any word is -- the pointer says which one it is.
    private static func pointerSweep(_ element: AXElement, value: String) {
        guard let frame = element.frame, frame.width > 0 else { return }
        guard let whole = element.wholeMarkerRange(),
              let start = TextMarkerBridge.startMarker(of: whole) else {
            print("     pointer map:  no start marker")
            return
        }

        let ns = value as NSString
        var samples: [String] = []
        let y = frame.minY + min(10, frame.height / 2)
        for step in 0..<6 {
            let x = frame.minX + 6 + CGFloat(step) * (frame.width - 12) / 6
            guard let marker = element.marker(atPosition: CGPoint(x: x, y: y)) else {
                samples.append("x+\(Int(x - frame.minX))=nil")
                continue
            }
            guard let span = element.markerRange(from: start, to: marker)
                    ?? TextMarkerBridge.range(from: start, to: marker),
                  let offset = element.length(ofMarkerRange: span) else {
                samples.append("x+\(Int(x - frame.minX))=marker,no-offset")
                continue
            }
            let char = offset >= 0 && offset < ns.length
                ? ns.substring(with: NSRange(location: offset, length: 1))
                : "?"
            samples.append("x+\(Int(x - frame.minX))=\(offset)'\(char)'")
        }
        print("     pointer map:  \(samples.joined(separator: "  "))")
    }

    private static func describe(_ rect: CGRect?) -> String {
        guard let rect else { return "no answer" }
        let text = "\(Int(rect.origin.x)),\(Int(rect.origin.y)) "
            + "\(Int(rect.size.width))x\(Int(rect.size.height))"
        return text + (AXElement.isDrawable(rect) ? "   <- DRAWABLE" : "   <- empty")
    }
}
