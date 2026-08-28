import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let hotkey = HotkeyMonitor()
    private let panel = SuggestionPanel()
    private var engine: HarperEngine?
    /// Nil when no GGUF model is installed; rewrite then reports that instead
    /// of failing silently.
    private var rewriter: RewriteEngine?
    private var live: LiveChecker?
    private var liveMenuItem: NSMenuItem?
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

        // The model is loaded lazily on first rewrite, not here: it is hundreds
        // of megabytes and most sessions never ask for a rewrite.
        if let config = rewriteConfig(modelName: nil) {
            rewriter = RewriteEngine(config: config)
        }

        let combo = hotkey.start { [weak self] in self?.trigger() }
        updateStatusTitle(combo: combo)

        if !AXAccess.isTrusted {
            AXAccess.requestTrust()
        }

        // Inline underlines are the product; the hotkey panel is the fallback
        // for fields that cannot show them. Starting this behind a menu toggle
        // meant the app looked like it did nothing until you found the toggle.
        startLiveWhenTrusted()
    }

    /// Starts inline underlining, waiting for permission if it is not granted
    /// yet. The user typically approves the prompt seconds after launch.
    @MainActor
    private func startLiveWhenTrusted() {
        guard let engine else { return }
        if AXAccess.isTrusted {
            if live == nil { live = LiveChecker(engine: engine) }
            live?.start()
            liveMenuItem?.state = .on
            return
        }
        Task { @MainActor [weak self] in
            for _ in 0..<60 { // give up after a minute
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.live?.isRunning != true else { return }
                if AXAccess.isTrusted {
                    self.startLiveWhenTrusted()
                    return
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine?.stop()
        hotkey.stop()
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // An icon rather than the word "nib", which is invisible among a dozen
        // other menu bar items.
        if let icon = NSImage(systemSymbolName: "pencil.line",
                              accessibilityDescription: "nib") {
            icon.isTemplate = true
            item.button?.image = icon
        } else {
            item.button?.title = "nib"
        }
        item.button?.font = .systemFont(ofSize: 12, weight: .medium)

        let menu = NSMenu()
        menu.addItem(withTitle: "Check Selection", action: #selector(trigger), keyEquivalent: "")
            .target = self

        let liveItem = NSMenuItem(title: "Underline As I Type",
                                  action: #selector(toggleLive), keyEquivalent: "")
        liveItem.target = self
        liveItem.state = .off
        menu.addItem(liveItem)
        liveMenuItem = liveItem

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

    /// Turns inline underlines on or off.
    ///
    /// Off by default. It polls the focused element and lints on every pause in
    /// typing, which is the right trade only once the user has asked for it.
    @MainActor
    @objc private func toggleLive() {
        guard AXAccess.isTrusted else {
            presentPermissionHelp()
            return
        }
        guard let engine else { return }

        if live?.isRunning == true {
            live?.stop()
            liveMenuItem?.state = .off
        } else {
            if live == nil { live = LiveChecker(engine: engine) }
            live?.start()
            liveMenuItem?.state = .on
        }
    }

    // MARK: - The flow

    @objc private func trigger() {
        guard AXAccess.isTrusted else {
            presentPermissionHelp()
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
                return await engine.withReplacements(
                    suggestions, in: grabbed.selectedText)
            },
            onRewrite: { [weak self] text, mode in
                guard let rewriter = self?.rewriter else {
                    throw RewriteError.modelMissing("no .gguf model found")
                }
                return try await rewriter.rewrite(text, mode: mode)
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

    /// Explains the case that looks like a macOS bug but is not: nib listed and
    /// switched on in Accessibility, yet still untrusted.
    ///
    /// Ad-hoc signing produces a new code hash on every build, and the grant is
    /// bound to that hash. Rebuilding leaves an entry that is toggled on and
    /// points at a binary that no longer exists. Only clearing the entry fixes
    /// it; toggling it off and on again does not.
    private func presentPermissionHelp() {
        let alert = NSAlert()
        alert.messageText = "nib cannot read your text"
        alert.informativeText = """
        nib needs Accessibility permission.

        If nib is ALREADY switched on in that list, the entry is stale: \
        rebuilding the app changes its signature and invalidates the grant. \
        Toggling it off and on will not help.

        To clear it, run:

            tccutil reset Accessibility com.kushagra.nib

        then relaunch nib and approve the prompt.
        """
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Copy Command")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            AXAccess.openSettings()
        case .alertSecondButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
                "tccutil reset Accessibility com.kushagra.nib", forType: .string)
        default:
            break
        }
    }

    private func presentFatal(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "nib"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
