import AppKit
import ApplicationServices

/// Follows the focused text field and reports when its text or geometry moves.
///
/// Focus changes are polled rather than observed. Observing them properly means
/// attaching an AXObserver to every running application and keeping that in
/// sync as apps launch and quit; polling one attribute a few times a second
/// costs almost nothing and does not go stale.
///
/// Text changes within a field ARE observed, because those need to be immediate
/// and can arrive per keystroke.
final class AXWatcher {
    /// Fires when the focused field changes, with its current text.
    var onFocusChanged: ((AXElement?, String) -> Void)?
    /// Fires when the focused field's text changes.
    var onTextChanged: ((String) -> Void)?
    /// Fires when the selection changes, with the selected text and its range.
    /// An empty string means the selection was cleared.
    var onSelectionChanged: ((String, NSRange) -> Void)?
    /// Fires when the field may have moved: scrolled, resized, window dragged.
    var onGeometryChanged: (() -> Void)?

    private var focusTimer: Timer?
    private var geometryTimer: Timer?
    private var observer: AXObserver?
    private var observedElement: AXElement?
    private var observedPID: pid_t?

    private(set) var current: AXElement?
    private var lastText = ""
    private var lastSelection = ""
    private var lastSelectionRange = NSRange(location: 0, length: 0)
    private var lastFrame: CGRect = .zero
    /// Where the sentinel range sat last time, to detect scrolling.
    private var lastSentinelRect: CGRect?

    func start() {
        stop()
        // Clicking into a field should feel immediate, and this poll is one
        // cheap attribute read.
        focusTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) {
            [weak self] _ in self?.pollFocus()
        }
        // A field can move without its text changing: window drag, scroll,
        // resize. Nothing notifies us, so the frame is sampled.
        geometryTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) {
            [weak self] _ in self?.pollGeometry()
        }
        pollFocus()
    }

    func stop() {
        focusTimer?.invalidate()
        focusTimer = nil
        geometryTimer?.invalidate()
        geometryTimer = nil
        detachObserver()
        current = nil
        lastText = ""
        lastFrame = .zero
    }

    // MARK: - Focus

    private func pollFocus() {
        guard AXAccess.isTrusted else { return }

        // Chromium apps expose nothing readable until asked. Done before
        // reading focus so the first poll after switching to Slack or VS Code
        // already sees a real tree rather than an empty one.
        ChromiumAccessibility.enableForFrontmost()

        let focused = AXElement.focused

        // Eligibility covers more than the role: password fields are ordinary
        // text fields wearing a secure subrole, and reading one would hand a
        // password to the linter.
        let eligible = focused.map {
            FieldEligibility.mayRead(role: $0.role,
                                     subrole: $0.string(for: kAXSubroleAttribute),
                                     label: FieldEligibility.label(of: $0))
        } ?? false

        guard let focused, eligible else {
            if current != nil {
                current = nil
                lastText = ""
                detachObserver()
                onFocusChanged?(nil, "")
            }
            return
        }

        // Same element as before: nothing to re-attach.
        if let current, CFEqual(current.raw, focused.raw) { return }

        current = focused
        lastText = focused.string(for: kAXValueAttribute) ?? ""
        lastFrame = AXGeometry.frame(of: focused) ?? .zero
        attachObserver(to: focused)
        onFocusChanged?(focused, lastText)
    }

    /// Set by the owner: false when there is nothing drawn, so the poll can
    /// skip its cross-process call entirely.
    var needsGeometry: (() -> Bool)?

    /// A range the owner is currently drawing, used to detect text movement.
    var sentinelRange: (() -> NSRange?)?

    private func pollGeometry() {
        guard let current, needsGeometry?() ?? true else { return }

        var moved = false

        let frame = AXGeometry.frame(of: current) ?? .zero
        if frame != lastFrame {
            lastFrame = frame
            moved = true
        }

        // Scrolling inside a field moves the TEXT but not the field, so the
        // frame is unchanged and marks silently drift out of alignment.
        // Sampling where one marked range actually sits catches that, and
        // catches reflow from a window resize too.
        if let range = sentinelRange?(), range.length > 0 {
            let rect = current.bounds(forRange: CFRange(location: range.location,
                                                        length: range.length))
            if rect != lastSentinelRect {
                lastSentinelRect = rect
                moved = true
            }
        }

        guard moved else { return }
        onGeometryChanged?()
    }

    // MARK: - Text changes

    private func attachObserver(to element: AXElement) {
        detachObserver()
        guard let pid = pidOf(element) else { return }

        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let watcher = Unmanaged<AXWatcher>.fromOpaque(refcon).takeUnretainedValue()
            DispatchQueue.main.async { watcher.textDidChange() }
        }
        guard AXObserverCreate(pid, callback, &created) == .success,
              let created else { return }

        let context = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(created, element.raw,
                                  kAXValueChangedNotification as CFString, context)
        AXObserverAddNotification(created, element.raw,
                                  kAXSelectedTextChangedNotification as CFString, context)
        CFRunLoopAddSource(CFRunLoopGetCurrent(),
                           AXObserverGetRunLoopSource(created), .defaultMode)

        observer = created
        observedElement = element
        observedPID = pid
    }

    private func detachObserver() {
        guard let observer else { return }
        if let element = observedElement {
            AXObserverRemoveNotification(observer, element.raw,
                                         kAXValueChangedNotification as CFString)
            AXObserverRemoveNotification(observer, element.raw,
                                         kAXSelectedTextChangedNotification as CFString)
        }
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(),
                              AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = nil
        observedElement = nil
        observedPID = nil
    }

    private func textDidChange() {
        guard let current else { return }

        // The same notification covers edits and selection changes, so both
        // are checked. Selecting text leaves the value untouched, and an
        // earlier version returned here and never reported the selection.
        let text = current.string(for: kAXValueAttribute) ?? ""
        if text != lastText {
            lastText = text
            onTextChanged?(text)
        }
        reportSelection()
    }

    private func reportSelection() {
        guard let current else { return }
        let selected = current.string(for: kAXSelectedTextAttribute) ?? ""
        let cfRange = current.range(for: kAXSelectedTextRangeAttribute)
        let range = cfRange.map { NSRange(location: $0.location, length: $0.length) }
            ?? NSRange(location: 0, length: 0)

        guard selected != lastSelection || range != lastSelectionRange else { return }
        lastSelection = selected
        lastSelectionRange = range
        onSelectionChanged?(selected, range)
    }

    private func pidOf(_ element: AXElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element.raw, &pid) == .success else { return nil }
        return pid
    }
}
