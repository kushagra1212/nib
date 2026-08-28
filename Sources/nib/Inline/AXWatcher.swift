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
    /// Fires when the field may have moved: scrolled, resized, window dragged.
    var onGeometryChanged: (() -> Void)?

    private var focusTimer: Timer?
    private var geometryTimer: Timer?
    private var observer: AXObserver?
    private var observedElement: AXElement?
    private var observedPID: pid_t?

    private(set) var current: AXElement?
    private var lastText = ""
    private var lastFrame: CGRect = .zero

    /// Text fields worth underlining. Buttons and labels report values too.
    private static let editableRoles: Set<String> = [
        kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole,
    ]

    func start() {
        stop()
        focusTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) {
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
        let focused = AXElement.focused

        guard let focused, let role = focused.role,
              Self.editableRoles.contains(role) else {
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

    private func pollGeometry() {
        guard let current, needsGeometry?() ?? true else { return }
        let frame = AXGeometry.frame(of: current) ?? .zero
        guard frame != lastFrame else { return }
        lastFrame = frame
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
        let text = current.string(for: kAXValueAttribute) ?? ""
        guard text != lastText else { return }
        lastText = text
        onTextChanged?(text)
    }

    private func pidOf(_ element: AXElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element.raw, &pid) == .success else { return nil }
        return pid
    }
}
