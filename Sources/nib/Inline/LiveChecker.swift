import AppKit

/// Watches the focused field, lints it as you type, and keeps the overlay in
/// sync. This is the always-on mode; the hotkey panel remains for fields where
/// inline underlines are not possible.
@MainActor
final class LiveChecker {
    private let watcher = AXWatcher()
    private let overlay = InlineOverlay()
    private let engine: HarperEngine

    private var element: AXElement?
    private var text = ""
    private var suggestions: [Suggestion] = []
    private var lintTask: Task<Void, Never>?
    private var mouseMonitor: Any?

    /// Fields longer than this are skipped. Underlining a 10,000-word document
    /// means thousands of AX bounds calls per keystroke, which stalls the app
    /// being typed into.
    private let maxLength = 4000

    private(set) var isRunning = false

    init(engine: HarperEngine) {
        self.engine = engine

        watcher.onFocusChanged = { [weak self] element, text in
            self?.focusChanged(element, text)
        }
        watcher.onTextChanged = { [weak self] text in
            self?.textChanged(text)
        }
        watcher.onGeometryChanged = { [weak self] in
            self?.redraw()
        }
        overlay.onAcceptFix = { [weak self] suggestion, replacement in
            self?.apply(suggestion, replacement)
        }
    }

    func start() {
        guard !isRunning, AXAccess.isTrusted else { return }
        isRunning = true
        watcher.start()
        // The overlay ignores mouse events, so hover is detected globally.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) {
            [weak self] _ in
            self?.overlay.mouseMoved(to: NSEvent.mouseLocation)
        }
    }

    func stop() {
        isRunning = false
        watcher.stop()
        lintTask?.cancel()
        overlay.hide()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }

    // MARK: - Reacting to the field

    private func focusChanged(_ element: AXElement?, _ text: String) {
        self.element = element
        self.text = text
        suggestions = []
        overlay.hide()
        guard element != nil else { return }
        scheduleLint()
    }

    private func textChanged(_ text: String) {
        self.text = text
        // Squiggles from the previous text are now in the wrong places.
        overlay.hide()
        scheduleLint()
    }

    /// Debounced so a burst of keystrokes lints once, at the end.
    private func scheduleLint() {
        lintTask?.cancel()
        let snapshot = text
        guard !snapshot.isEmpty, snapshot.count <= maxLength else {
            suggestions = []
            return
        }

        lintTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            guard self.text == snapshot else { return } // superseded

            guard let found = try? await self.engine.lint(snapshot) else { return }
            guard !Task.isCancelled, self.text == snapshot else { return }

            // Replacements are needed up front here, unlike the panel: the
            // hover card must offer a fix the instant the pointer arrives.
            let capped = Array(found.prefix(40))
            let filled = await self.engine.withReplacements(capped)
            guard !Task.isCancelled, self.text == snapshot else { return }

            self.suggestions = filled
            self.redraw()
        }
    }

    private func redraw() {
        guard let element, !suggestions.isEmpty,
              let frame = AXGeometry.frame(of: element) else {
            overlay.hide()
            return
        }
        let marks = AXGeometry.rects(for: suggestions, in: element)
        // Clip to the field: a scrolled-away line still reports bounds, which
        // would paint squiggles over whatever is above or below the field.
        let visible = marks.filter { frame.intersects($0.rect) }
        overlay.show(fieldFrame: frame, marks: visible)
    }

    // MARK: - Applying a fix

    private func apply(_ suggestion: Suggestion, _ replacement: String) {
        guard let element else { return }
        let nsText = text as NSString
        guard NSMaxRange(suggestion.range) <= nsText.length else { return }

        let updated = nsText.replacingCharacters(in: suggestion.range, with: replacement)

        // Prefer a targeted replacement: setting the whole value moves the
        // caret to the end, which is intolerable mid-sentence.
        let cfRange = CFRange(location: suggestion.range.location,
                              length: suggestion.range.length)
        var applied = false
        if var range = Optional(cfRange),
           let axRange = AXValueCreate(.cfRange, &range),
           element.isSettable(kAXSelectedTextRangeAttribute),
           element.set(kAXSelectedTextRangeAttribute, to: axRange),
           element.isSettable(kAXSelectedTextAttribute) {
            applied = element.set(kAXSelectedTextAttribute, to: replacement as CFString)
        }
        if !applied, element.isSettable(kAXValueAttribute) {
            applied = element.set(kAXValueAttribute, to: updated as CFString)
        }
        guard applied else { return }

        text = updated
        overlay.hide()
        scheduleLint()
    }
}
