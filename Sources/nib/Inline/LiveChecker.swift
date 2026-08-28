import AppKit

/// Watches the focused field, lints it as you type, and keeps the overlay in
/// sync. This is the always-on mode; the hotkey panel remains for fields where
/// inline underlines are not possible.
@MainActor
final class LiveChecker {
    private let watcher = AXWatcher()
    private let overlay = InlineOverlay()
    private let badge = IssueBadge()
    private let selectionBar = SelectionBar()

    /// Shown in the badge for fields that cannot be underlined. Set by the app
    /// delegate once it knows which combo actually registered.
    var hotkeyLabel = "⌥Space"
    /// Called when the badge is clicked -- same action as the hotkey.
    var onOpenPanel: (() -> Void)?
    /// The selection the bar is currently offering to rewrite.
    private var selectionRange: NSRange?
    private var selectionTask: Task<Void, Never>?
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
    private var redrawPending = false
    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?

    /// Fields longer than this are skipped. Underlining a 10,000-word document
    /// means thousands of AX bounds calls per keystroke, which stalls the app
    /// being typed into.
    private let maxLength = 4000

    private(set) var isRunning = false

    /// Last outcome of each pipeline stage, for the diagnostic.
    ///
    /// Every stage failing looks the same from outside -- no marks -- and the
    /// stage that fails is not visible from the app, so it is recorded.
    private var lastLintCount = -1
    private var lastRectCount = -1
    private var lastVisibleCount = -1
    private var lastFieldFrame: CGRect = .zero
    private var lastNote = "nothing yet"

    /// What the live checker currently sees. Read by the menu diagnostic.
    func report() -> String {
        var lines: [String] = []
        lines.append("running:        \(isRunning ? "yes" : "NO")")
        lines.append("trusted:        \(AXAccess.isTrusted ? "yes" : "NO")")

        if let element {
            lines.append("element role:   \(element.role ?? "?")")
            lines.append("element subrole:\(element.string(for: kAXSubroleAttribute) ?? "none")")
            let label = FieldEligibility.label(of: element)
            lines.append("label:          \(label?.prefix(48) ?? "none")")
            let eligible = FieldEligibility.mayRead(
                role: element.role,
                subrole: element.string(for: kAXSubroleAttribute),
                label: label)
            lines.append("eligible:       \(eligible ? "yes" : "NO")")
        } else {
            lines.append("element:        NONE — watcher is holding no field")
        }

        lines.append("text length:    \(text.count)")
        lines.append("suggestions:    \(suggestions.count)"
                     + " (\(suggestions.filter { $0.kind == .correction }.count) correction,"
                     + " \(suggestions.filter { $0.kind == .clarity }.count) clarity)")
        lines.append("lint returned:  \(lastLintCount)")
        lines.append("rects resolved: \(lastRectCount)")
        lines.append("rects visible:  \(lastVisibleCount)")
        lines.append("field frame:    \(Int(lastFieldFrame.origin.x)),"
                     + "\(Int(lastFieldFrame.origin.y)) "
                     + "\(Int(lastFieldFrame.width))x\(Int(lastFieldFrame.height))")
        lines.append("overlay shown:  \(overlay.isVisible ? "yes" : "no")")
        lines.append("note:           \(lastNote)")

        // The live path holds an element captured when focus changed; the
        // probe fetches a fresh one. Chromium rebuilds its tree constantly, so
        // these can be different objects with different capabilities. Asking
        // both the same question is the only way to tell those apart.
        lines.append("")
        lines.append("bounds, cached element:")
        lines.append(boundsReport(for: element))
        lines.append("bounds, fresh element:")
        lines.append(boundsReport(for: AXElement.focused))
        return lines.joined(separator: "\n")
    }

    private func boundsReport(for element: AXElement?) -> String {
        guard let element else { return "  (none)" }
        var out: [String] = []

        let probes: [(String, CFRange)] = [
            ("  at 0, len 1:  ", CFRange(location: 0, length: 1)),
            ("  at 0, len 4:  ", CFRange(location: 0, length: 4)),
            ("  suggestion:   ", suggestions.first.map {
                CFRange(location: $0.range.location, length: $0.range.length)
            } ?? CFRange(location: 0, length: 1)),
        ]
        for (label, range) in probes {
            if let rect = element.bounds(forRange: range) {
                out.append("\(label)\(Int(rect.origin.x)),\(Int(rect.origin.y)) "
                           + "\(Int(rect.width))x\(Int(rect.height))")
            } else {
                out.append("\(label)nil")
            }
        }
        // Whether the attribute is advertised at all, which is a different
        // question from whether it answers.
        var names: CFArray?
        let err = AXUIElementCopyParameterizedAttributeNames(element.raw, &names)
        let list = (names as? [String]) ?? []
        out.append("  param attrs:  \(err == .success ? "\(list.count)" : "error \(err.rawValue)")")
        out.append("  has bounds:   "
                   + (list.contains(kAXBoundsForRangeParameterizedAttribute as String)
                      ? "yes" : "NO"))
        return out.joined(separator: "\n")
    }

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
            self?.selectionBar.dismiss()
            self?.overlay.isSuppressed = false
        }
        watcher.onSelectionChanged = { [weak self] selected, range in
            self?.selectionChanged(selected, range)
        }
        // Nothing on screen means nothing to reposition, so the geometry poll
        // can skip its cross-process call while the text is clean.
        watcher.needsGeometry = { [weak self] in
            !(self?.suggestions.isEmpty ?? true)
        }
        watcher.sentinelRange = { [weak self] in
            self?.suggestions.first?.range
        }
        badge.onOpen = { [weak self] in
            self?.onOpenPanel?()
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
        // The overlay ignores mouse events, so hover has to be watched for.
        //
        // Both monitors are needed. A global monitor sees events destined for
        // OTHER apps and stops the moment nib itself becomes frontmost, which
        // happens as soon as the card is clicked -- after which hovering did
        // nothing until focus moved away again. A local monitor covers that
        // gap. Dragging is included so hover still tracks while selecting.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged]
        ) { [weak self] _ in
            self?.overlay.mouseMoved(to: NSEvent.mouseLocation)
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged]
        ) { [weak self] event in
            self?.overlay.mouseMoved(to: NSEvent.mouseLocation)
            return event
        }
    }

    func stop() {
        isRunning = false
        watcher.stop()
        lintTask?.cancel()
        modelTask?.cancel()
        selectionTask?.cancel()
        selectionBar.dismiss()
        overlay.isSuppressed = false
        hideMarks()
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        mouseMonitor = nil
        localMouseMonitor = nil
    }

    // MARK: - Reacting to the field

    private func focusChanged(_ element: AXElement?, _ text: String) {
        self.element = element
        self.text = text
        suggestions = []
        dismissed.removeAll()
        hideMarks()
        guard element != nil else { return }
        scheduleLint()
    }

    private func textChanged(_ text: String) {
        self.text = text
        // Squiggles from the previous text are now in the wrong places, and
        // the selection the bar was offering to rewrite no longer exists.
        hideMarks()
        selectionBar.dismiss()
        overlay.isSuppressed = false
        selectionTask?.cancel()
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
            // Harper answers in ~30ms, so a long debounce is all dead time.
            // Just enough to coalesce a burst of keystrokes.
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self else { return }
            guard self.text == snapshot else { return } // superseded

            guard let found = try? await self.engine.lint(snapshot) else {
                self.lastNote = "lint threw or was cancelled"
                return
            }
            self.lastLintCount = found.count
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
                self.suggestions = Self.merge(
                    harper: self.suggestions.filter { $0.kind == .correction },
                    model: SuggestionFilter.apply(found, in: snapshot),
                    in: snapshot)
                self.redraw()
            }

            // Clarity last: it is the slowest and the least urgent, so
            // corrections are already on screen by the time it lands.
            let clarity = await model.clarity(snapshot)
            guard !Task.isCancelled, self.text == snapshot, !clarity.isEmpty else { return }

            // Clarity waits for the errors in its sentence to be fixed.
            //
            // A rewrite of a sentence that still contains typos is built on
            // the typos: the model either preserves them or invents around
            // them, and either way the suggestion is wrong. Offering it
            // alongside the spelling fix also asks the reader to choose
            // between two answers to different questions.
            //
            // Corrections stay first in the array so hit-testing prefers
            // them: hovering a marked word offers its fix, hovering elsewhere
            // in a clean sentence offers the rewrite.
            let corrections = self.suggestions.filter { $0.kind == .correction }
            let settled = clarity.filter { sentence in
                !corrections.contains {
                    NSIntersectionRange($0.range, sentence.range).length > 0
                }
            }
            self.suggestions = corrections + settled
            self.redraw()
        }
    }

    /// Coalesces redraw requests into one per frame.
    ///
    /// Geometry is sampled several times a second and each redraw costs one
    /// cross-process AX call per mark, so a scroll used to fire hundreds of
    /// them a second on the main thread. Merging every request that lands
    /// within a frame collapses that back to one pass.
    /// Shows the rewrite bar over a selection worth rewriting.
    ///
    /// Debounced, because a drag emits a selection change per pixel and the
    /// bar would flicker along behind the pointer.
    private func selectionChanged(_ selected: String, _ range: NSRange) {
        selectionTask?.cancel()

        let trimmed = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        // Short selections are usually a click or a double-clicked word, and
        // there is nothing useful to rewrite in either.
        guard trimmed.count >= 12, WordDiff.tokenize(trimmed).count >= 3 else {
            selectionBar.dismiss()
            overlay.isSuppressed = false
            selectionRange = nil
            return
        }
        guard let model else {
            // Without a model there is nothing to offer, and a bar that only
            // reports its own absence is worse than no bar.
            selectionBar.dismiss()
            overlay.isSuppressed = false
            return
        }

        selectionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self, let element = self.element else { return }

            let rects = AXGeometry.lineRects(for: range, in: element)
            guard let anchor = rects.max(by: { $0.maxY < $1.maxY }) else { return }

            self.selectionRange = range
            self.selectionBar.onRewrite = { mode in
                try await model.rewriteSelection(trimmed, mode: mode)
            }
            self.selectionBar.onAccept = { [weak self] replacement in
                self?.replaceSelection(range, with: replacement, original: selected)
            }
            // The bar takes over this region; the hover card would otherwise
            // open on top of it.
            self.overlay.isSuppressed = true
            self.selectionBar.prepare(original: trimmed)
            self.selectionBar.present(above: anchor)
        }
    }

    private func replaceSelection(_ range: NSRange, with replacement: String,
                                  original: String) {
        let suggestion = Suggestion(range: range, message: "Rewrite",
                                    replacements: [replacement])
        apply(suggestion, replacement)
        selectionRange = nil
    }

    /// Widest a model edit may be and still count as a correction.
    ///
    /// Beyond this it is a rewrite of the phrase, not a fix to a word, and
    /// marking it red claims a certainty the model does not have.
    static let maxCorrectionWords = 4

    /// Combines harper's word-level marks with the model's.
    ///
    /// The model pass used to replace harper's results outright, which is what
    /// made precise marks vanish and a band appear across the line: a
    /// sentence-level rewrite diffs into one wide span, and that span replaced
    /// three exact words.
    ///
    /// Harper is precise about what it does know, so its marks are kept. The
    /// model contributes what harper missed, and only where it is pointing at
    /// something small enough to be a correction.
    static func merge(
        harper: [Suggestion], model: [Suggestion], in text: String
    ) -> [Suggestion] {
        var out = harper
        for candidate in model {
            let words = WordDiff.tokenize(candidate.excerpt(in: text) ?? "").count
            guard words <= maxCorrectionWords else { continue }
            // Harper already flagged this span, and its range is tighter.
            let overlaps = harper.contains {
                NSIntersectionRange($0.range, candidate.range).length > 0
            }
            guard !overlaps else { continue }
            out.append(candidate)
        }
        return out.sorted { $0.range.location < $1.range.location }
    }

    private func redraw() {
        guard redrawPending == false else { return }
        redrawPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) { [weak self] in
            self?.redrawPending = false
            self?.redrawNow()
        }
    }

    private func redrawNow() {
        guard let element else {
            lastNote = "no element"
            hideMarks()
            return
        }
        guard !suggestions.isEmpty else {
            lastNote = "no suggestions to draw"
            hideMarks()
            return
        }
        guard let frame = AXGeometry.frame(of: element) else {
            lastNote = "element reports no frame"
            hideMarks()
            return
        }
        lastFieldFrame = frame
        let live = suggestions.filter { !dismissed.contains(key(for: $0)) }
        let marks = AXGeometry.rects(for: live, in: element)
        // Clip to the field: a scrolled-away line still reports bounds, which
        // would paint marks over whatever is above or below the field.
        lastRectCount = marks.reduce(0) { $0 + $1.rects.count }
        let placed = MarkPlacement.place(marks: marks, fieldFrame: frame)
        lastVisibleCount = placed.reduce(0) { $0 + $1.rects.count }
        lastNote = placed.isEmpty
            ? (marks.isEmpty
                ? "no bounds returned for any range"
                : "every rect fell outside the field frame")
            : "drew \(placed.count) marks"

        // Nothing placeable but plenty found. Slack and other Chromium apps
        // answer the bounds attribute with an empty rectangle, so there is
        // nowhere to draw and never will be. Say so rather than look broken.
        if placed.isEmpty {
            overlay.hide()
            badge.show(count: live.count, hint: hotkeyLabel, near: frame)
            return
        }
        badge.dismiss()
        overlay.show(fieldFrame: frame, marks: placed.map { ($0.suggestion, $0.rects) },
                     context: text)
    }

    /// Clears both ways of showing suggestions.
    private func hideMarks() {
        overlay.hide()
        badge.dismiss()
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
                hideMarks()
                scheduleLint()
                return
            }
            edit = moved
        }
        guard let updated = EditPlanner.apply(edit, to: current) else { return }
        let suggestion = Suggestion(id: suggestion.id, range: edit.range,
                                    message: suggestion.message,
                                    replacements: suggestion.replacements)

        // 1. Select the range and type over it.
        //
        //    Typing goes through the app's normal input path, so the edit
        //    lands in its undo stack and Cmd-Z reverts it. AX writes do not:
        //    they change the text without the app noticing, leaving the user
        //    with an edit they cannot take back. That is why this is first
        //    despite being slower than setting the value directly.
        if selectRange(suggestion.range, on: element) {
            Keystroke.type(replacement)
            if await settled(to: updated, on: element) {
                finish(updated)
                return
            }
        }

        // 2. Replace just the selection through AX. No undo entry, but it
        //    keeps the caret where it was.
        if selectRange(suggestion.range, on: element),
           element.set(kAXSelectedTextAttribute, to: replacement as CFString),
           await settled(to: updated, on: element) {
            finish(updated)
            return
        }

        // 3. Rewrite the whole value. Widest support, no undo entry, and it
        //    moves the caret to the end of the field.
        if element.isSettable(kAXValueAttribute),
           element.set(kAXValueAttribute, to: updated as CFString),
           await settled(to: updated, on: element) {
            finish(updated)
            return
        }

        // A late-landing write from any route above must not be followed by
        // another attempt; that is what produced a duplicated word.
        if await settled(to: updated, on: element, attempts: 2) {
            finish(updated)
            return
        }
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
        hideMarks()
        scheduleLint()
    }
}
