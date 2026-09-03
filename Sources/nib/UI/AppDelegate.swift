import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let hotkey = HotkeyMonitor()
    private let panel = SuggestionPanel()
    private var engine: HarperEngine?
    /// Nil when no GGUF model is installed; rewrite then reports that instead
    /// of failing silently.
    private var rewriter: RewriteEngine?
    private var live: LiveChecker?
    private var liveMenuItem: NSMenuItem?
    private var loginMenuItem: NSMenuItem?
    private var statusMenuItem: NSMenuItem?
    private var modelMenuItem: NSMenuItem?
    private var dictationMenuItem: NSMenuItem?
    private let dictationHotkey = HotkeyMonitor(identifier: 2)

    private var speechMenuItem: NSMenuItem?
    private var memoryMenuItem: NSMenuItem?
    private var historyMenuItem: NSMenuItem?
    private var dictationHistory = DictationHistory.load()
    private var voiceMenuItem: NSMenuItem?
    // Two monitors, two identifiers. Carbon delivers every press to every
    // handler, so sharing one would make hush start speech as well.
    private let speakHotkey = HotkeyMonitor(identifier: 3)
    private let hushHotkey = HotkeyMonitor(identifier: 4)
    @MainActor private lazy var speech = makeSpeech()
    /// Both own main-actor state, so they are built on first use there.
    @MainActor private lazy var dictation = makeDictation()
    @MainActor private lazy var dictationOverlay = makeDictationOverlay()
    /// Built on first use. It owns a window, so it stays on the main actor.
    @MainActor private lazy var modelSetup = makeModelSetup()
    private var permissionWatch: Task<Void, Never>?
    /// Held between opening the panel and applying, so the result goes back to
    /// the field it came from.
    private var target: TextTarget?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.reset()
        Log.write("launched, trusted=\(AXAccess.isTrusted)")
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

        // Offers to fetch a model, once, and only when there is none. Someone
        // who already has one, or who closed this window on a previous launch,
        // never sees it.
        modelSetup.showOnFirstLaunchIfNeeded()

        // A previous nib that crashed or was force-quit leaves its
        // llama-server behind, holding the whole model. Nothing else collects
        // it, so the next launch does.
        RewriteEngine.reapOrphans()

        startDictation()
    }

    // MARK: - Dictation

    @MainActor
    private func startDictation() {
        // Both carried over from the setup nib replaces, so the keys already
        // in people's fingers keep working once the server is gone.
        // Logged on success too, not only on failure. Registering silently
        // meant "it worked" and "this line never ran" looked identical in the
        // log, which is the state this was debugged from.
        if let speak = speakHotkey.start(preferring: [.controlCommandN],
                                         onFire: { [weak self] in self?.speech.toggle() }) {
            Log.write("speak hotkey registered on \(speak.label)")
        } else {
            Log.write("speak hotkey unavailable -- something else holds ⌃⌘N")
        }
        if let hush = hushHotkey.start(preferring: [.controlShiftH],
                                       onFire: { [weak self] in self?.speech.hush() }) {
            Log.write("hush hotkey registered on \(hush.label)")
        } else {
            Log.write("hush hotkey unavailable -- something else holds ⌃⇧H")
        }

        let combo = dictationHotkey.start(preferring: [.controlOptionD]) {
            [weak self] in self?.dictation.toggle()
        }
        if combo == nil {
            Log.write("dictation hotkey unavailable -- something else holds it")
        }
        // Compiles whisper's Metal shaders now rather than during the first
        // dictation, where the wait would be half a minute.
        if SpeechModelCatalog.installed() != nil {
            DictationController.warmUpMetal()
        }
    }

    @MainActor
    private func recordTranscript(_ text: String) {
        dictationHistory.add(text)
        dictationHistory.save()
        rebuildHistoryMenu()
    }

    /// The last dictations, newest first, click to copy.
    ///
    /// Fifteen in the menu of the hundred kept: a menu longer than the screen
    /// scrolls, and anything past the last few is being searched for rather
    /// than browsed. The file has the rest.
    @MainActor
    private func rebuildHistoryMenu() {
        guard let item = historyMenuItem else { return }
        let entries = dictationHistory.entries

        guard !entries.isEmpty else {
            item.submenu = nil
            item.isEnabled = false
            item.title = "Recent Dictation — none yet"
            return
        }

        item.isEnabled = true
        item.title = "Recent Dictation"
        let menu = NSMenu()
        for entry in entries.prefix(15) {
            let row = NSMenuItem(title: entry.label(),
                                 action: #selector(copyTranscript(_:)),
                                 keyEquivalent: "")
            row.target = self
            row.representedObject = entry.text
            row.toolTip = entry.text
            menu.addItem(row)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear History",
                               action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
        item.submenu = menu
    }

    @MainActor
    @objc private func copyTranscript(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Log.write("dictation: copied \(text.count) characters from history")
    }

    @MainActor
    @objc private func clearHistory() {
        dictationHistory.clear()
        dictationHistory.save()
        rebuildHistoryMenu()
        Log.write("dictation: history cleared")
    }

    @MainActor
    private func makeDictation() -> DictationController {
        let controller = DictationController()
        controller.onStateChange = { [weak self] state in
            self?.dictationOverlay.show(state)
            self?.updateDictationMenuItem()
            if case .failed(let why) = state { self?.reportDictation(why) }
        }
        // Whisper and llama-server both want the GPU, and this machine has
        // already been measured failing to hold two models at once.
        controller.willTranscribe = { [weak self] in
            guard let rewriter = self?.rewriter else { return }
            Task { await rewriter.shutdown() }
        }
        controller.onNeedsModel = { [weak self] in self?.offerSpeechModel() }
        controller.onTranscript = { [weak self] text in
            MainActor.assumeIsolated { self?.recordTranscript(text) }
        }
        return controller
    }

    @MainActor
    private func makeDictationOverlay() -> DictationOverlay {
        let overlay = DictationOverlay()
        overlay.sample = { [weak self] in
            guard let self else { return (0, 0) }
            return (self.dictation.level, self.dictation.elapsed)
        }
        overlay.onCancel = { [weak self] in self?.dictation.cancel() }
        return overlay
    }

    @MainActor
    private func offerSpeechModel() {
        let alert = NSAlert()
        alert.messageText = "No speech model installed"
        alert.informativeText = """
        Dictation needs a speech model, which runs on this machine. Nothing \
        you say is uploaded.

        Put a whisper .bin model in:
           ~/Library/Application Support/nib/speech

        Whisper small is a good starting point at 190MB.
        """
        alert.addButton(withTitle: "Open Folder")
        alert.addButton(withTitle: "Copy Download Command")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let folder = SpeechModelCatalog.installDirectory
            try? FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        case .alertSecondButtonReturn:
            let model = SpeechModelCatalog.recommended
            let command = """
            mkdir -p ~/Library/Application\\ Support/nib/speech && \
            curl -L -o ~/Library/Application\\ Support/nib/speech/\(model.filename) \
            \(model.url.absoluteString)
            """
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        default:
            break
        }
    }

    @MainActor
    private func reportDictation(_ why: String) {
        let alert = NSAlert()
        alert.messageText = "Dictation stopped"
        alert.informativeText = why

        // A dialog that names a permission and offers only OK is a dead end:
        // it leaves the reader to find a settings pane nib can open in one
        // line.
        //
        // Which pane depends on which permission failed, and dictation needs
        // two. A microphone refusal that opens the Accessibility list sends
        // someone to a switch that is already on, to fix something else.
        enum Missing { case microphone, accessibility, neither }
        let missing: Missing = why.contains("microphone")
            ? .microphone
            : (AXAccess.isTrusted ? .neither : .accessibility)

        switch missing {
        case .microphone:
            alert.addButton(withTitle: "Open Microphone Settings")
        case .accessibility:
            alert.addButton(withTitle: "Open Accessibility Settings")
        case .neither:
            break
        }
        alert.addButton(withTitle: "OK")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        switch missing {
        case .microphone:    AXAccess.openMicrophoneSettings()
        case .accessibility: AXAccess.openSettings()
        case .neither:       break
        }
    }

    @MainActor
    private func updateDictationMenuItem() {
        guard let item = dictationMenuItem else { return }
        let combo = dictationHotkey.active?.label ?? "unavailable"
        switch dictation.state {
        case .recording:    item.title = "Stop Dictating  (\(combo))"
        case .transcribing: item.title = "Transcribing…"
        default:            item.title = "Dictate  (\(combo))"
        }
    }

    @MainActor
    @objc private func toggleDictation() {
        dictation.toggle()
    }

    @MainActor
    private func makeSpeech() -> SpeechController {
        let controller = SpeechController()
        controller.onStateChange = { [weak self] _ in
            MainActor.assumeIsolated { self?.updateSpeechMenuItem() }
        }
        return controller
    }

    @MainActor
    private func refreshMemoryMenuItem() {
        guard let item = memoryMenuItem else { return }
        let reading = Footprint.read()
        item.title = "Memory: \(reading.summary)"
        // Nothing to hand back when the engines are already down, and a live
        // menu item that does nothing is worse than a greyed one.
        item.isEnabled = reading.helpers > 0
        item.toolTip = reading.helpers > 0
            ? "Shut the rewrite and grammar engines down now. They restart when "
                + "next used, and go on their own after two minutes idle."
            : "Nothing loaded. The engines start when used and release "
                + "themselves after two minutes."
    }

    @MainActor
    @objc private func freeMemory() {
        speech.release()
        if let rewriter {
            Task { await rewriter.shutdown() }
        }
        Log.write("memory: released on request")
        // Give the processes a moment to go before reporting what is left.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated { self?.refreshMemoryMenuItem() }
        }
    }

    @MainActor
    private func updateSpeechMenuItem() {
        guard let item = speechMenuItem else { return }
        let combo = speakHotkey.active?.label ?? "unavailable"
        switch speech.state {
        case .speaking:
            let stop = hushHotkey.active?.label ?? combo
            item.title = "Stop Speaking  (\(stop))"
        case .preparing, .synthesising:
            item.title = speech.state.label
        case .failed(let why):
            item.title = "Speak Selection  — \(why.prefix(40))"
        case .idle:
            item.title = VoiceCatalog.isInstalled
                ? "Speak Selection  (\(combo))"
                : "Speak Selection  — download the voice first"
        }
    }

    /// The 54 voices, grouped by the prefix kokoro names them with.
    ///
    /// Flat, a list of 54 is unreadable; grouped, it is nine short menus. The
    /// prefixes are the model's own: "af" is American female, "bm" British
    /// male, and so on.
    @MainActor
    private func rebuildVoiceMenu() {
        guard let voiceItem = voiceMenuItem else { return }

        guard let pack = VoiceCatalog.installedVoicePack,
              let voices = try? VoicePack(url: pack) else {
            voiceItem.submenu = nil
            voiceItem.isEnabled = false
            voiceItem.title = "Voice  — download the voice first"
            return
        }

        voiceItem.isEnabled = true
        voiceItem.title = "Voice"
        let menu = NSMenu()
        var lastPrefix = ""
        for name in voices.names {
            let prefix = String(name.prefix(2))
            if prefix != lastPrefix {
                if !lastPrefix.isEmpty { menu.addItem(.separator()) }
                lastPrefix = prefix
            }
            let item = NSMenuItem(title: VoiceNames.title(for: name),
                                  action: #selector(chooseVoice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.state = name == speech.voice ? .on : .off
            menu.addItem(item)
        }
        voiceItem.submenu = menu
    }

    @MainActor private lazy var voiceSetup: VoiceSetupWindow = {
        let setup = VoiceSetupWindow()
        setup.onInstalled = { [weak self] in
            MainActor.assumeIsolated {
                self?.rebuildVoiceMenu()
                self?.updateSpeechMenuItem()
            }
        }
        return setup
    }()

    @MainActor
    @objc private func showVoiceSetup() {
        voiceSetup.show()
    }

    @MainActor
    @objc private func toggleSpeech() {
        speech.toggle()
    }

    @MainActor
    @objc private func chooseVoice(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        speech.voice = name
        Log.write("speech: voice set to \(name)")
        rebuildVoiceMenu()
    }

    @MainActor
    private func makeModelSetup() -> ModelSetupWindow {
        let setup = ModelSetupWindow()
        setup.onInstalled = { [weak self] path in self?.adoptModel(at: path) }
        return setup
    }

    /// Starts using a model that was just installed, without a restart.
    ///
    /// The live checker captured the model checker when it was built, and at
    /// that point there was no model, so it holds nil. Handing it a new engine
    /// is not enough -- it has to be rebuilt, or the rewrite bar goes on not
    /// appearing until the app is next launched.
    @MainActor
    private func adoptModel(at path: URL) {
        guard let server = locateLlamaServer() else { return }
        rewriter = RewriteEngine(
            config: .init(serverBinary: server, modelPath: path))
        Log.write("model installed: \(path.lastPathComponent)")

        if let engine, live?.isRunning == true {
            live?.stop()
            live = makeLiveChecker(engine: engine)
            live?.start()
        }
        refreshModelMenuItem()
    }

    private func refreshModelMenuItem() {
        modelMenuItem?.title = rewriteConfig(modelName: nil) == nil
            ? "Set Up AI Rewrite…"
            : "AI Rewrite: ready"
    }

    @MainActor
    private func makeLiveChecker(engine: HarperEngine) -> LiveChecker {
        let checker = LiveChecker(engine: engine, model: modelChecker())
        // Fields that report no drawable bounds show a count instead. It opens
        // the same panel the hotkey does, so the label has to match whichever
        // combo actually registered.
        checker.hotkeyLabel = hotkey.active?.label ?? "menu bar"
        checker.onOpenPanel = { [weak self] in self?.trigger() }
        return checker
    }

    /// Starts inline underlining, waiting for permission if it is not granted
    /// yet. The user typically approves the prompt seconds after launch.
    @MainActor
    private func startLiveWhenTrusted() {
        guard let engine else { return }
        if AXAccess.isTrusted {
            if live == nil {
                live = makeLiveChecker(engine: engine)
            }
            live?.start()
            liveMenuItem?.state = .on
            return
        }
        // Waits indefinitely. An earlier version gave up after a minute, which
        // meant that approving the prompt any later than that left inline
        // underlining switched off for the rest of the session -- while the
        // hotkey kept working, because it checks permission on demand. The
        // result looked exactly like "nib does not work in this app".
        guard permissionWatch == nil else { return }
        permissionWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                guard self.live?.isRunning != true else {
                    self.permissionWatch = nil
                    return
                }
                if AXAccess.isTrusted {
                    self.permissionWatch = nil
                    self.startLiveWhenTrusted()
                    return
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine?.stop()
        hotkey.stop()
        dictationHotkey.stop()
        speakHotkey.stop()
        hushHotkey.stop()
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

        // One line saying whether nib is actually working, before the things
        // you can do to it. Every other item describes a single part, and
        // reading four of them to work out "is it on" is a poor way to ask a
        // simple question.
        let status = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        statusMenuItem = status
        menu.addItem(.separator())

        menu.addItem(withTitle: "Check Selection", action: #selector(trigger), keyEquivalent: "")
            .target = self

        let liveItem = NSMenuItem(title: "Underline As I Type",
                                  action: #selector(toggleLive), keyEquivalent: "")
        liveItem.target = self
        liveItem.state = .off
        menu.addItem(liveItem)
        liveMenuItem = liveItem
        menu.delegate = self

        menu.addItem(.separator())

        // AI features are inactive without a model, and silence is the worst
        // way to communicate that.
        let modelItem = NSMenuItem(title: "",
                                   action: #selector(showModelSetup), keyEquivalent: "")
        modelItem.target = self
        menu.addItem(modelItem)
        modelMenuItem = modelItem
        refreshModelMenuItem()

        let dictateItem = NSMenuItem(title: "Dictate",
                                     action: #selector(toggleDictation),
                                     keyEquivalent: "")
        dictateItem.target = self
        menu.addItem(dictateItem)
        dictationMenuItem = dictateItem
        MainActor.assumeIsolated { updateDictationMenuItem() }

        // Dictation types into whatever has focus, so a transcript that lands
        // in the wrong window is otherwise gone. These are kept instead.
        let historyItem = NSMenuItem(title: "Recent Dictation", action: nil,
                                     keyEquivalent: "")
        menu.addItem(historyItem)
        historyMenuItem = historyItem
        MainActor.assumeIsolated { rebuildHistoryMenu() }

        let speakItem = NSMenuItem(title: "Speak Selection",
                                   action: #selector(toggleSpeech), keyEquivalent: "")
        speakItem.target = self
        menu.addItem(speakItem)
        speechMenuItem = speakItem

        // A submenu rather than a window: 54 voices is a list to scroll, not a
        // thing to configure, and the menu is already where nib's settings are.
        let voiceSetupItem = NSMenuItem(title: "Voices…",
                                        action: #selector(showVoiceSetup),
                                        keyEquivalent: "")
        voiceSetupItem.target = self
        menu.addItem(voiceSetupItem)

        let voiceItem = NSMenuItem(title: "Voice", action: nil, keyEquivalent: "")
        menu.addItem(voiceItem)
        voiceMenuItem = voiceItem
        MainActor.assumeIsolated {
            updateSpeechMenuItem()
            rebuildVoiceMenu()
        }

        // What nib is costing, and a way to hand it back.
        //
        // The engines are separate processes, so Activity Monitor shows "nib"
        // at 100MB and "llama-server" at 2.7GB with nothing connecting them.
        // This is the one place the total is visible.
        let memoryItem = NSMenuItem(title: "", action: #selector(freeMemory),
                                    keyEquivalent: "")
        memoryItem.target = self
        menu.addItem(memoryItem)
        memoryMenuItem = memoryItem

        let loginItem = NSMenuItem(title: "Start at Login",
                                   action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        loginMenuItem = loginItem

        menu.addItem(withTitle: "Accessibility Settings…",
                     action: #selector(openAccessibility), keyEquivalent: "").target = self

        // Runs under nib's own permission, unlike the command line probes,
        // which are attributed to whichever terminal launched them.
        let diagnose = NSMenuItem(title: "Diagnose Frontmost App…",
                                  action: #selector(diagnoseField), keyEquivalent: "")
        diagnose.target = self
        menu.addItem(diagnose)

        // Reports what the live checker itself holds, which is different from
        // what the AX probe can reach: the probe asks the system, this asks
        // the running pipeline.
        let liveDiagnose = NSMenuItem(title: "Diagnose Live Checking…",
                                      action: #selector(diagnoseLive), keyEquivalent: "")
        liveDiagnose.target = self
        menu.addItem(liveDiagnose)

        menu.addItem(withTitle: "Dictation Words…",
                     action: #selector(editVocabulary),
                     keyEquivalent: "").target = self

        menu.addItem(withTitle: "Licences…", action: #selector(showLicences),
                     keyEquivalent: "").target = self

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit nib", action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    /// Refreshes the menu each time it opens, so its state is current rather
    /// than whatever was true at launch.
    func menuWillOpen(_ menu: NSMenu) {
        refreshStatusLine()
        refreshMemoryMenuItem()
        // A model can arrive while the app is running, from this window or
        // from someone dropping a file into the folder.
        refreshModelMenuItem()
        MainActor.assumeIsolated { updateDictationMenuItem() }

        let running = live?.isRunning == true
        liveMenuItem?.state = running ? .on : .off
        liveMenuItem?.title = running
            ? "Underline As I Type"
            : (AXAccess.isTrusted
                ? "Underline As I Type — off"
                : "Underline As I Type — needs permission")

        // Read rather than remembered: this can be switched off in System
        // Settings without nib being told.
        switch LoginItem.state {
        case .on:
            loginMenuItem?.state = .on
            loginMenuItem?.title = "Start at Login"
        case .off:
            loginMenuItem?.state = .off
            loginMenuItem?.title = "Start at Login"
        case .blockedBySystemSettings:
            loginMenuItem?.state = .off
            loginMenuItem?.title = "Start at Login — blocked in Settings…"
        case .unsupported:
            loginMenuItem?.state = .off
            loginMenuItem?.title = "Start at Login — unavailable"
        }
    }

    /// The one line at the top: what is working, or what is stopping it.
    ///
    /// Ordered by what blocks what. Without Accessibility nib cannot read a
    /// single character, so nothing below it matters and nothing else is
    /// mentioned until it is granted.
    @MainActor
    private func refreshStatusLine() {
        guard let item = statusMenuItem else { return }

        guard AXAccess.isTrusted else {
            item.attributedTitle = Self.statusText(
                "Not working — needs Accessibility permission", tint: .systemRed)
            return
        }
        guard live?.isRunning == true else {
            item.attributedTitle = Self.statusText(
                "Underlines off — turn on below", tint: .systemOrange)
            return
        }

        guard let rewriter else {
            item.attributedTitle = Self.statusText(
                "Working — no AI model", tint: .systemGreen)
            return
        }

        // "installed" is about a file on disk. "ready" is about a server that
        // answered. They are different claims, and the AI item below only ever
        // makes the weaker one.
        //
        // The engine is an actor, so its state cannot be read while building a
        // menu. The line is written twice: the certain part now, the rest a
        // moment later, while the menu is still open.
        item.attributedTitle = Self.statusText(
            "Working — AI model installed", tint: .systemGreen)
        Task { @MainActor in
            let loaded = await rewriter.isLoaded
            item.attributedTitle = Self.statusText(
                loaded ? "Working — AI ready" : "Working — AI loads on first use",
                tint: .systemGreen)
        }
    }

    private static func statusText(_ text: String, tint: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .foregroundColor: tint,
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
        ])
    }

    private func updateStatusTitle(combo: HotkeyMonitor.Combo?) {
        guard let button = statusItem?.button else { return }
        button.toolTip = combo.map { "nib — press \($0.label)" }
            ?? "nib — no hotkey available, use the menu"
    }

    @objc private func openAccessibility() {
        AXAccess.openSettings()
    }

    /// Opens the window that downloads and checks a model.
    ///
    /// This replaced a wall of instructions telling people to install
    /// llama.cpp, create a directory and find a GGUF. Every step of that was
    /// something the app could do, and each one was a place to give up.
    @MainActor
    @objc private func showModelSetup() {
        modelSetup.show()
    }

    /// Opens the list of words dictation should expect.
    ///
    /// Whisper replaces any name it has never seen with the nearest real word,
    /// so "Hasura" arrives as "Azure" until it is listed. This is the fix for
    /// that, and it has to be reachable or nobody will know it exists.
    @MainActor
    @objc private func editVocabulary() {
        NSWorkspace.shared.open(SpeechVocabulary.createFileIfNeeded())
    }

    /// Opens the licences of the binaries nib ships.
    @objc private func showLicences() {
        guard let path = Bundle.main.url(forResource: "THIRD-PARTY-LICENSES",
                                         withExtension: "txt") else {
            // A checkout run from the command line has no bundle to read from.
            NSWorkspace.shared.open(
                URL(string: "https://github.com/kushagra1212/nib/blob/main/THIRD-PARTY-LICENSES.txt")!)
            return
        }
        NSWorkspace.shared.open(path)
    }

    /// Reports what nib can see in the app that was frontmost.
    ///
    /// Counts down first, because opening the menu makes nib frontmost and the
    /// app under investigation is whatever the user goes back to.
    @objc private func diagnoseField() {
        guard AXAccess.isTrusted else {
            presentPermissionHelp()
            return
        }

        let notice = NSAlert()
        notice.messageText = "Click into the field you want to check"
        notice.informativeText = """
        Press Start, then click into the text field in the app you are testing. \
        The report appears five seconds later.
        """
        notice.addButton(withTitle: "Start")
        notice.addButton(withTitle: "Cancel")
        guard notice.runModal() == .alertFirstButtonReturn else { return }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)

            let report: String
            if let found = AXProbe.probeFocused() {
                report = """
                app:              \(found.app)
                role:             \(found.role)
                read value:       \(found.canReadValue ? "yes (\(found.valueLength) chars)" : "NO")
                read selection:   \(found.canReadSelection ? "yes" : "no")
                write value:      \(found.valueSettable ? "yes" : "no")
                write selection:  \(found.selectionSettable ? "yes" : "no")
                bounds, 1 char:   \(found.boundsForRange == nil ? "NO" : "yes")
                bounds, 4 chars:  \(found.boundsForWord ? "yes" : "NO")

                \(found.verdict)
                """
            } else {
                report = AXProbe.diagnoseNoFocus()
            }

            let result = NSAlert()
            result.messageText = "What nib can see"
            result.informativeText = report
            result.addButton(withTitle: "Copy")
            result.addButton(withTitle: "Done")
            if result.runModal() == .alertFirstButtonReturn {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report, forType: .string)
            }
        }
    }

    /// Reports the live checker's own state, stage by stage.
    @objc private func diagnoseLive() {
        let notice = NSAlert()
        notice.messageText = "Type in the field you want to check"
        notice.informativeText = """
        Press Start, click into the field, and type a misspelled word. \
        The report appears eight seconds later and shows which stage stopped.
        """
        notice.addButton(withTitle: "Start")
        notice.addButton(withTitle: "Cancel")
        guard notice.runModal() == .alertFirstButtonReturn else { return }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            let report = live?.report() ?? "live checker was never created"

            let result = NSAlert()
            result.messageText = "Live checking"
            result.informativeText = report
            result.addButton(withTitle: "Copy")
            result.addButton(withTitle: "Done")
            if result.runModal() == .alertFirstButtonReturn {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(report, forType: .string)
            }
        }
    }

    /// The model-backed second pass, or nil when no GGUF model is installed.
    private func modelChecker() -> ModelChecker? {
        guard let rewriter else { return nil }
        return ModelChecker(rewriter: rewriter)
    }

    @MainActor
    @objc private func toggleLoginItem() {
        // Once macOS marks the item as needing approval, only the user can
        // clear that. Sending them there beats a dialog that says no twice.
        if LoginItem.state == .blockedBySystemSettings {
            LoginItem.openSettings()
            return
        }

        if let problem = LoginItem.set(!LoginItem.isEnabled) {
            let alert = NSAlert()
            alert.messageText = "Could not change Start at Login"
            alert.informativeText = problem
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
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
            if live == nil {
                live = makeLiveChecker(engine: engine)
            }
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
                guard let self else {
                    throw RewriteError.modelMissing("nib is shutting down")
                }
                guard let rewriter = self.rewriter else {
                    // Pressing the button is the clearest statement anyone can
                    // make that they want this feature, so offer to install it
                    // rather than reporting that it is missing.
                    await MainActor.run { self.modelSetup.show() }
                    throw RewriteError.modelMissing("no model installed")
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
        case .typed, .wroteInPlace, .pasted:
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
