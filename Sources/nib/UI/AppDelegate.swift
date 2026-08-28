import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let hotkey = HotkeyMonitor()
    private let panel = SuggestionPanel()
    private var engine: HarperEngine?
    /// Held between opening the panel and applying, so the result goes back to
    /// the field it came from.
    private var target: TextTarget?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()

        guard let harper = locateHarper() else {
            presentFatal("harper-ls is missing from the app bundle.")
            return
        }
        engine = HarperEngine(executable: harper)

        // Warm the engine now so the first hotkey press is not a cold start.
        Task { try? await engine?.start() }

        let combo = hotkey.start { [weak self] in self?.trigger() }
        updateStatusTitle(combo: combo)

        if !AXAccess.isTrusted {
            AXAccess.requestTrust()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine?.stop()
        hotkey.stop()
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "nib"
        item.button?.font = .systemFont(ofSize: 12, weight: .medium)

        let menu = NSMenu()
        menu.addItem(withTitle: "Check Selection", action: #selector(trigger), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Accessibility Settings…",
                     action: #selector(openAccessibility), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit nib", action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    private func updateStatusTitle(combo: HotkeyMonitor.Combo?) {
        guard let button = statusItem?.button else { return }
        button.toolTip = combo.map { "nib — press \($0.label)" }
            ?? "nib — no hotkey available, use the menu"
    }

    @objc private func openAccessibility() {
        AXAccess.openSettings()
    }

    // MARK: - The flow

    @objc private func trigger() {
        guard AXAccess.isTrusted else {
            presentFatal("nib needs Accessibility permission to read the text you are editing.")
            AXAccess.openSettings()
            return
        }
        guard let grabbed = TextGrabber.grab(), !grabbed.selectedText.isEmpty else {
            presentFatal("Could not read any text from the frontmost app.")
            return
        }
        target = grabbed

        let mouse = NSEvent.mouseLocation
        panel.present(
            text: grabbed.selectedText,
            near: NSPoint(x: mouse.x, y: mouse.y),
            onApply: { [weak self] edited in self?.writeBack(edited) },
            requestFixes: { [weak self] suggestions in
                guard let engine = self?.engine else { return suggestions }
                return await engine.withReplacements(suggestions)
            }
        )

        Task { @MainActor [weak self] in
            guard let self, let engine = self.engine else { return }
            do {
                let found = try await engine.lint(grabbed.selectedText)
                self.panel.show(found)
            } catch {
                self.panel.showError("check failed: \(error)")
            }
        }
    }

    private func writeBack(_ edited: String) {
        guard let target else { return }
        switch TextWriter.replace(target, with: edited) {
        case .wroteInPlace, .pasted:
            break
        case .copiedToClipboard:
            presentFatal("Could not write to that app. The result is on your clipboard.")
        }
        self.target = nil
    }

    private func presentFatal(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "nib"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
