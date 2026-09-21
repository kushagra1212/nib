import AppKit

/// The window that gets AI rewrite working.
///
/// It opens itself once, on the first launch that finds no model, and never
/// again uninvited. If a model is already installed it says so and offers
/// nothing to do -- there is no setup to walk through when setup is done.
@MainActor
final class ModelSetupWindow: NSObject, NSWindowDelegate {
    /// Set after the first automatic appearance, so the second launch is quiet
    /// whether or not anything was installed. Someone who closed this window
    /// has answered the question.
    private static let seenKey = "ModelSetupShown"

    /// Handed the installed model so rewriting can start without a restart.
    var onInstalled: ((URL) -> Void)?

    private var window: NSWindow?
    private let installer = ModelInstaller()
    private var chosen = ModelCatalog.recommended
    private var body = NSStackView()

    /// Download speed, from the last progress callback rather than the whole
    /// transfer: an average over ten minutes hides the connection dropping.
    private var lastSample: (date: Date, bytes: Int64)?
    private var speed: Double?

    // MARK: - Opening

    /// Opens only if there is nothing working yet, and only the first time.
    /// Returns whether it opened.
    @discardableResult
    func showOnFirstLaunchIfNeeded() -> Bool {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.seenKey) else { return false }
        defaults.set(true, forKey: Self.seenKey)
        guard rewriteConfig(modelName: nil) == nil else { return false }
        show()
        return true
    }

    func show() {
        if let window {
            place(window)
            raise(window)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "AI Rewrite"
        window.delegate = self
        window.isReleasedWhenClosed = false

        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 14
        body.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        body.translatesAutoresizingMaskIntoConstraints = false

        // The aurora, same as every floating panel. This window built a plain
        // NSView and so was the one surface the backdrop never reached -- and
        // it is the one a new user spends longest looking at.
        let content = Theme.makeAurora()
        content.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: content.topAnchor),
            body.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        self.window = window

        installer.onChange = { [weak self] _ in self?.render() }
        render()
        place(window)
        raise(window)
    }

    /// Centres on the screen the pointer is on.
    ///
    /// NSWindow.center() uses the screen macOS considers main, which on a
    /// two-display desk is regularly not the one being looked at. A first-run
    /// window that opens on the other monitor may as well not have opened.
    private func place(_ window: NSWindow) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            // Slightly above centre, where a dialog is expected to sit.
            y: visible.midY - size.height / 2 + visible.height * 0.08))
    }

    /// Brings the window to the front from a menu bar app.
    ///
    /// An accessory app does not reliably win activation: on the first run the
    /// window opened behind whatever was already frontmost, which looked
    /// exactly like nothing happening. orderFrontRegardless is the part that
    /// does not depend on being granted activation.
    private func raise(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Closing mid-download would leave the transfer running with nothing
        // showing it, so it stops with the window.
        if installer.isBusy { installer.cancel() }
        return true
    }

    // MARK: - Rendering

    private func render() {
        guard let window else { return }
        body.arrangedSubviews.forEach {
            body.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        switch installer.stage {
        case .idle:
            if let config = rewriteConfig(modelName: nil) {
                renderReady(model: config.modelPath)
            } else {
                renderChoices()
            }
        case let .downloading(fraction, received, total):
            renderDownloading(fraction: fraction, received: received, total: total)
        case .verifying:
            renderVerifying()
        case let .done(path):
            renderInstalled(path)
        case let .failed(message):
            renderFailed(message)
        case .cancelled:
            renderChoices()
        }

        window.layoutIfNeeded()
        let height = body.fittingSize.height
        var frame = window.frame
        let target = window.frameRect(forContentRect:
            NSRect(x: 0, y: 0, width: 460, height: height))
        // From the top edge, so the window does not appear to jump up the
        // screen every time the content changes size.
        frame.origin.y += frame.height - target.height
        frame.size = target.size
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    // MARK: - States

    private func renderReady(model: URL) {
        add(title: "AI rewrite is ready")
        add(caption: "Using \(model.lastPathComponent).\n\nFix, Clearer, "
            + "Shorter and Freely are available on any selection, and "
            + "sentences are checked for clarity as you type.")
        addRow([
            button("Show in Finder", action: #selector(revealModel)),
            .spacer,
            button("Done", action: #selector(close), primary: true),
        ])
    }

    private func renderChoices() {
        add(title: "Add a model")
        add(caption: "Grammar checking already works. The rewrite buttons and "
            + "the blue clarity underlines need a language model, which runs "
            + "on this machine -- nothing you write is uploaded.")

        for model in ModelCatalog.all {
            let row = ModelRow(model: model, selected: model == chosen)
            row.onSelect = { [weak self] in
                self?.chosen = model
                self?.render()
            }
            body.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: body.widthAnchor,
                                       constant: -44).isActive = true
        }

        add(caption: "Any other GGUF works too -- nib is not limited to this "
            + "list. Larger is not automatically better: the 1.7B models were "
            + "tried and were worse at correcting short sentences.")

        addRow([
            button("Not Now", action: #selector(close)),
            button("Choose File…", action: #selector(chooseFile)),
            .spacer,
            button("Download \(chosen.sizeLabel)",
                   action: #selector(startDownload), primary: true),
        ])
    }

    private func renderDownloading(fraction: Double, received: Int64, total: Int64) {
        // A file already on disk is being copied, not fetched, and calling
        // that "downloading" is the sort of small lie that makes people doubt
        // the rest of the window.
        let verb = chosen.url.isFileURL ? "Installing" : "Downloading"
        add(title: "\(verb) \(chosen.title)")

        let bar = NSProgressIndicator()
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = fraction
        bar.controlSize = .large
        body.addArrangedSubview(bar)
        bar.widthAnchor.constraint(equalTo: body.widthAnchor,
                                   constant: -44).isActive = true

        add(caption: "\(megabytes(received)) of \(megabytes(total))"
            + (remaining(received: received, total: total).map { "  ·  \($0)" } ?? ""))
        addRow([.spacer, button("Cancel", action: #selector(cancelDownload))])
    }

    private func renderVerifying() {
        add(title: "Checking the model")

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let label = NSTextField(labelWithString:
            "Loading it and asking it to correct one sentence.")
        label.font = Theme.Font.body
        label.textColor = Theme.Colour.inkMuted
        let row = NSStackView(views: [spinner, label])
        row.spacing = 8
        body.addArrangedSubview(row)
    }

    private func renderInstalled(_ path: URL) {
        add(title: "Ready")
        add(caption: "\(path.lastPathComponent) is installed and working.\n\n"
            + "Select any text and the rewrite bar now offers Fix, Clearer, "
            + "Shorter and Freely. No restart needed.")
        onInstalled?(path)
        addRow([.spacer, button("Done", action: #selector(close), primary: true)])
    }

    private func renderFailed(_ message: String) {
        add(title: "That did not work")
        add(caption: message)
        addRow([
            button("Choose Another", action: #selector(backToChoices)),
            .spacer,
            button("Try Again", action: #selector(startDownload), primary: true),
        ])
    }

    // MARK: - Actions

    @objc private func startDownload() {
        installer.reset()
        lastSample = nil
        speed = nil
        installer.start(chosen)
    }

    @objc private func cancelDownload() {
        installer.cancel()
    }

    /// Installs a GGUF the user already has, through the same path a download
    /// takes -- so it is copied into place and checked, not just pointed at.
    @objc private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a GGUF model"
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        guard picked.pathExtension.lowercased() == "gguf" else {
            installer.reset()
            let alert = NSAlert()
            alert.messageText = "That is not a GGUF file"
            alert.informativeText = "nib runs models in the .gguf format that "
                + "llama.cpp reads. \(picked.lastPathComponent) is not one."
            alert.runModal()
            return
        }
        chosen = ModelCatalog.local(picked)
        startDownload()
    }

    @objc private func backToChoices() {
        installer.reset()
        render()
    }

    @objc private func revealModel() {
        guard let config = rewriteConfig(modelName: nil) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([config.modelPath])
    }

    @objc private func close() {
        window?.performClose(nil)
    }

    // MARK: - Formatting

    private func megabytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_000_000
        return mb >= 1000
            ? String(format: "%.2f GB", mb / 1000)
            : String(format: "%.0f MB", mb)
    }

    /// Time left, once there is enough of a sample to mean anything.
    private func remaining(received: Int64, total: Int64) -> String? {
        let now = Date()
        if let last = lastSample {
            let elapsed = now.timeIntervalSince(last.date)
            if elapsed > 0.4 {
                let sample = Double(received - last.bytes) / elapsed
                // Smoothed, or the estimate flickers between numbers too fast
                // to read on any connection that is not perfectly steady.
                speed = speed.map { $0 * 0.7 + sample * 0.3 } ?? sample
                lastSample = (now, received)
            }
        } else {
            lastSample = (now, received)
        }

        guard let speed, speed > 100_000, total > received else { return nil }
        let seconds = Int(Double(total - received) / speed)
        if seconds < 60 { return "less than a minute left" }
        let minutes = (seconds + 30) / 60
        return minutes == 1 ? "about a minute left" : "about \(minutes) minutes left"
    }

    // MARK: - Building blocks

    private func add(title: String) {
        let label = NSTextField(labelWithString: title)
        label.font = Theme.Font.heading
        body.addArrangedSubview(label)
    }

    private func add(caption: String) {
        let label = NSTextField(wrappingLabelWithString: caption)
        label.font = Theme.Font.body
        label.textColor = Theme.Colour.inkMuted
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        body.addArrangedSubview(label)
        label.widthAnchor.constraint(equalTo: body.widthAnchor,
                                     constant: -44).isActive = true
    }

    /// The same control as the rewrite bar and the dictation overlay.
    ///
    /// This window used AppKit's rounded bezel, which is a different height, a
    /// different radius and a different typeface from everything else nib
    /// draws -- so the one window a new user meets first looked like it came
    /// from another application.
    private func button(_ title: String, action: Selector,
                        primary: Bool = false) -> NSView {
        PillButton(title: title,
                   emphasis: primary ? .primary : .secondary,
                   tint: Theme.Colour.brass,
                   target: self, action: action)
    }

    private func addRow(_ views: [NSView]) {
        let row = NSStackView(views: views)
        row.spacing = 10
        body.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: body.widthAnchor,
                                   constant: -44).isActive = true
    }
}

private extension NSView {
    /// Pushes what follows it to the far edge of a row.
    static var spacer: NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        return view
    }
}

/// One selectable model in the list.
private final class ModelRow: NSView {
    var onSelect: (() -> Void)?
    private let selected: Bool

    init(model: CatalogModel, selected: Bool) {
        self.selected = selected
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.control
        layer?.cornerCurve = .continuous
        layer?.borderWidth = selected ? 2 : 1

        let dot = NSImageView()
        dot.image = NSImage(
            systemSymbolName: selected ? "largecircle.fill.circle" : "circle",
            accessibilityDescription: selected ? "Selected" : "Not selected")
        dot.contentTintColor = selected ? Theme.Colour.selection : Theme.Colour.inkMuted

        let name = NSTextField(labelWithString: model.title)
        name.font = Theme.Font.rowTitle

        let size = NSTextField(labelWithString: model.sizeLabel)
        size.font = Theme.Font.caption
        size.textColor = Theme.Colour.inkMuted

        let heading = NSStackView(views: [name, size])
        heading.spacing = 8

        let detail = NSTextField(wrappingLabelWithString: model.detail)
        detail.font = Theme.Font.caption
        detail.textColor = Theme.Colour.inkMuted

        let text = NSStackView(views: [heading, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3

        let row = NSStackView(views: [dot, text])
        row.alignment = .top
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        refreshColours()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColours()
    }

    private func refreshColours() {
        layer?.borderColor = selected
            ? Theme.Colour.selection.cgColor
            : Theme.Colour.controlEdge(0.12).cgColor
        layer?.backgroundColor = selected
            ? Theme.Colour.selection.withAlphaComponent(0.08).cgColor
            : NSColor.clear.cgColor
    }

    override func mouseDown(with event: NSEvent) { onSelect?() }
}
