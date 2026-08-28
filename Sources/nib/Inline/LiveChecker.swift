import AppKit

/// Watches the focused field, lints it as you type, and keeps the overlay in
/// sync. This is the always-on mode; the hotkey panel remains for fields where
/// inline underlines are not possible.
@MainActor
final class LiveChecker {
    private let watcher = AXWatcher()
    private let overlay = InlineOverlay()
    private let engine: HarperEngine
    /// Optional second pass. Harper reads words; this reads sentences.
    private let model: ModelChecker?
    private var modelTask: Task<Void, Never>?

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

    init(engine: HarperEngine, model: ModelChecker? = nil) {
        self.engine = engine
        self.model = model

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
        modelTask?.cancel()
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
            let filled = await self.engine.withReplacements(capped, in: snapshot)
            guard !Task.isCancelled, self.text == snapshot else { return }

            self.suggestions = filled
            self.redraw()
            self.scheduleModelPass(for: snapshot)
        }
    }

    /// Second pass: the model rereads the whole text and its edits supersede
    /// harper's.
    ///
    /// Harper is two orders of magnitude faster, so it goes first and its marks
    /// appear immediately. The model then reruns on a longer pause with the
    /// context harper lacks, which is what stops `NSString` being "corrected"
    /// to `Nesting`. If the model returns nothing usable, harper's marks stand.
    private func scheduleModelPass(for snapshot: String) {
        guard let model else { return }
        modelTask?.cancel()
        modelTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled, let self, self.text == snapshot else { return }

            let found = await model.check(snapshot)
            guard !Task.isCancelled, self.text == snapshot else { return }
            if !found.isEmpty {
                self.suggestions = SuggestionFilter.apply(found, in: snapshot)
                self.redraw()
            }

            // Clarity last: it is the slowest and the least urgent, so
            // corrections are already on screen by the time it lands.
            let clarity = await model.clarity(snapshot)
            guard !Task.isCancelled, self.text == snapshot, !clarity.isEmpty else { return }

            // Only mark sentences that hold no error. A red and a blue mark on
            // the same words is two answers to one question.
            let corrections = self.suggestions.filter { $0.kind == .correction }
            let clean = clarity.filter { sentence in
                !corrections.contains { NSIntersectionRange($0.range, sentence.range).length > 0 }
            }
            self.suggestions = corrections + clean
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

    private func apply(_ suggestion: Suggestion, _ replacement: String) {
        Task { @MainActor [weak self] in
            await self?.performApply(suggestion, replacement)
        }
    }

    /// Replaces one flagged range, trying three routes in order of fidelity.
    ///
    /// Each route is confirmed by reading the value back, because
    /// AXUIElementSetAttributeValue returns success even when an app ignores
    /// the write. Crucially the read-back POLLS: apps apply AX writes
    /// asynchronously, and checking immediately saw stale text, declared the
    /// write a failure, and ran the next route too -- applying the same fix
    /// twice and leaving a duplicate word at the caret.
    private func performApply(_ suggestion: Suggestion, _ replacement: String) async {
        guard let element else { return }

        // Re-read rather than trusting the cached copy. Between the lint and
        // the click the user may have typed, which moves every offset; writing
        // a range computed against stale text overwrites the wrong span.
        let current = element.string(for: kAXValueAttribute) ?? text
        text = current

        var edit = TextEdit(range: suggestion.range,
                            replacement: replacement,
                            expected: suggestion.excerpt(in: current) ?? "")
        if !EditPlanner.isValid(edit, in: current) {
            guard let moved = EditPlanner.relocate(edit, in: current) else {
                // The flagged text is gone; nothing sensible left to replace.
                overlay.hide()
                scheduleLint()
                return
            }
            edit = moved
        }
        guard let updated = EditPlanner.apply(edit, to: current) else { return }
        let suggestion = Suggestion(id: suggestion.id, range: edit.range,
                                    message: suggestion.message,
                                    replacements: suggestion.replacements)

        // 1. Replace just the selection. Preferred: the caret stays put.
        if selectRange(suggestion.range, on: element),
           element.set(kAXSelectedTextAttribute, to: replacement as CFString),
           await settled(to: updated, on: element) {
            finish(updated)
            return
        }

        // 2. Rewrite the whole value. Wider support, but moves the caret to
        //    the end of the field.
        if element.isSettable(kAXValueAttribute),
           element.set(kAXValueAttribute, to: updated as CFString),
           await settled(to: updated, on: element) {
            finish(updated)
            return
        }

        // A late-landing write from either route above must not be followed by
        // a third attempt; that is what produced the duplicate.
        if await settled(to: updated, on: element, attempts: 2) {
            finish(updated)
            return
        }

        // 3. Type over the selection. Electron fields expose their text and
        //    silently refuse AX writes to it; synthetic input is what lands.
        guard selectRange(suggestion.range, on: element) else { return }
        Keystroke.type(replacement)
        _ = await settled(to: updated, on: element)
        finish(element.string(for: kAXValueAttribute) ?? updated)
    }

    private func selectRange(_ range: NSRange, on element: AXElement) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let axRange = AXValueCreate(.cfRange, &cfRange) else { return false }
        return element.set(kAXSelectedTextRangeAttribute, to: axRange)
    }

    /// Polls until the field holds `expected`, or the attempts run out.
    private func settled(
        to expected: String, on element: AXElement, attempts: Int = 8
    ) async -> Bool {
        for _ in 0..<attempts {
            if element.string(for: kAXValueAttribute) == expected { return true }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return element.string(for: kAXValueAttribute) == expected
    }

    private func finish(_ updated: String) {
        text = updated
        overlay.hide()
        scheduleLint()
    }
}
