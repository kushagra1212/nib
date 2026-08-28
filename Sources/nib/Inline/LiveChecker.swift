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
    /// Suggestions the user waved away, cleared when focus moves elsewhere.
    private var dismissed: Set<String> = []
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
        overlay.onDismissFix = { [weak self] suggestion in
            self?.dismiss(suggestion)
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
        dismissed.removeAll()
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
        let live = suggestions.filter { !dismissed.contains(key(for: $0)) }
        let marks = AXGeometry.rects(for: live, in: element)
        // Clip to the field: a scrolled-away line still reports bounds, which
        // would paint marks over whatever is above or below the field.
        let visible = marks.filter { frame.intersects($0.rect) }
        overlay.show(fieldFrame: frame, marks: visible, context: text)
    }

    /// Hides one suggestion until its text changes.
    ///
    /// Keyed by the flagged word plus the message rather than by id, because a
    /// re-lint mints new ids and a dismissal keyed on id would come straight
    /// back on the next keystroke.
    private func dismiss(_ suggestion: Suggestion) {
        dismissed.insert(key(for: suggestion))
        redraw()
    }

    private func key(for suggestion: Suggestion) -> String {
        let word = suggestion.excerpt(in: text) ?? ""
        return "\(word)|\(suggestion.message)"
    }

    // MARK: - Applying a fix

    /// Replaces one flagged range, trying three routes in order of fidelity.
    ///
    /// `AXUIElementSetAttributeValue` reports success by return code, but some
    /// apps return success and change nothing, so each route is verified by
    /// reading the text back rather than trusting the result.
    private func apply(_ suggestion: Suggestion, _ replacement: String) {
        guard let element else { return }
        let nsText = text as NSString
        guard NSMaxRange(suggestion.range) <= nsText.length else { return }

        let updated = nsText.replacingCharacters(in: suggestion.range, with: replacement)

        // Select the range first. Every route below needs it, and it is also
        // what makes the change visible if the write itself fails.
        var cfRange = CFRange(location: suggestion.range.location,
                              length: suggestion.range.length)
        let selected: Bool
        if let axRange = AXValueCreate(.cfRange, &cfRange) {
            selected = element.set(kAXSelectedTextRangeAttribute, to: axRange)
        } else {
            selected = false
        }

        // 1. Replace just the selection. Preferred: the caret stays put.
        if selected, element.set(kAXSelectedTextAttribute, to: replacement as CFString),
           didApply(updated, on: element) {
            finish(updated)
            return
        }

        // 2. Rewrite the whole value. Works more widely, but moves the caret
        //    to the end of the field.
        if element.isSettable(kAXValueAttribute),
           element.set(kAXValueAttribute, to: updated as CFString),
           didApply(updated, on: element) {
            finish(updated)
            return
        }

        // 3. Type over the selection. Electron fields expose their text but
        //    reject AX writes to it, silently: the range highlights and
        //    nothing else happens. Synthetic input is what actually lands.
        guard selected else { return }
        Keystroke.type(replacement)
        // The app applies the keystroke asynchronously, so re-read shortly.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self, let element = self.element else { return }
            let now = element.string(for: kAXValueAttribute) ?? ""
            self.finish(now.isEmpty ? updated : now)
        }
    }

    /// Confirms the field really holds the new text.
    private func didApply(_ expected: String, on element: AXElement) -> Bool {
        element.string(for: kAXValueAttribute) == expected
    }

    private func finish(_ updated: String) {
        text = updated
        overlay.hide()
        scheduleLint()
    }
}
