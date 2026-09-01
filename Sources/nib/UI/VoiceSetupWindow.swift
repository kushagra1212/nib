import AppKit

/// Downloads the two files speaking needs.
///
/// Separate from `ModelSetupWindow` because the shape of the choice is
/// different. That one offers three models and you pick one; this one needs
/// both of its files and there is nothing to decide -- so it is a single
/// button, and the only interesting states are progress and failure.
///
/// The model is 326MB and the voices 28MB. Downloaded in that order so the
/// long one starts while attention is still on the window.
@MainActor
final class VoiceSetupWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let body = NSStackView()
    private var installer: ModelInstaller?

    /// What is being fetched now, and what is left after it.
    private var queue: [CatalogModel] = []
    private var current: CatalogModel?
    private var failure: String?

    var onInstalled: (() -> Void)?

    func show() {
        if let window {
            place(window)
            raise(window)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 280),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Voices"
        window.delegate = self
        window.isReleasedWhenClosed = false

        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 14
        body.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        body.translatesAutoresizingMaskIntoConstraints = false

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

        render()
        place(window)
        raise(window)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // A transfer with no window showing it is a transfer nobody can stop.
        installer?.cancel()
        installer = nil
        queue = []
        current = nil
        return true
    }

    // MARK: - Downloading

    @objc private func startDownload() {
        failure = nil
        queue = VoiceCatalog.needed
        next()
    }

    @objc private func cancelDownload() {
        installer?.cancel()
        installer = nil
        queue = []
        current = nil
        render()
    }

    private func next() {
        guard !queue.isEmpty else {
            current = nil
            installer = nil
            Log.write("speech: voice files installed")
            onInstalled?()
            render()
            return
        }

        let model = queue.removeFirst()
        current = model

        // verifies: false. The verifier loads the file as a GGUF and asks it to
        // rewrite a sentence -- right for the llama model, meaningless for a
        // 326MB ONNX graph and a numpy archive, which it would reject.
        let installer = ModelInstaller(destinationDirectory: VoiceCatalog.installDirectory,
                                       verifies: false)
        self.installer = installer
        installer.onChange = { [weak self] stage in
            MainActor.assumeIsolated { self?.handle(stage) }
        }
        installer.start(model)
        render()
    }

    private func handle(_ stage: ModelInstaller.Stage) {
        switch stage {
        case .done:
            next()
        case .failed(let why):
            failure = why
            current = nil
            queue = []
            render()
        case .cancelled:
            current = nil
            queue = []
            render()
        default:
            render()
        }
    }

    // MARK: - Rendering

    private func render() {
        body.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if let failure {
            add(title: "That did not work")
            add(caption: failure)
            add(button: "Try Again", action: #selector(startDownload))
            return
        }

        if let current, let installer {
            add(title: "Downloading \(current.title)")
            if case .downloading(let fraction, let received, let total) = installer.stage {
                add(caption: "\(megabytes(received)) of \(megabytes(total))"
                    + "  ·  \(Int(fraction * 100))%")
                let bar = NSProgressIndicator()
                bar.isIndeterminate = false
                bar.minValue = 0
                bar.maxValue = 1
                bar.doubleValue = fraction
                bar.translatesAutoresizingMaskIntoConstraints = false
                bar.widthAnchor.constraint(equalToConstant: 380).isActive = true
                body.addArrangedSubview(bar)
            } else {
                add(caption: "Starting…")
            }
            if !queue.isEmpty {
                add(caption: "Then: \(queue.map(\.title).joined(separator: ", "))")
            }
            add(button: "Cancel", action: #selector(cancelDownload), primary: false)
            return
        }

        guard !VoiceCatalog.isInstalled else {
            add(title: "Ready to speak")
            add(caption: "Select text anywhere and press ⌃⌘N. ⌃⇧H stops it.")
            add(caption: "Pick a voice from nib's menu — there are 54.")
            return
        }

        add(title: "Reading aloud needs two files")
        for model in VoiceCatalog.needed {
            add(caption: "\(model.title)  ·  \(model.sizeLabel)  —  \(model.detail)")
        }
        add(caption: "They stay on this machine. Nothing is sent anywhere.")
        add(button: "Download", action: #selector(startDownload))
    }

    // The same helpers as ModelSetupWindow, deliberately. Two setup windows
    // built from different type and different buttons look like two
    // applications, which is the drift Theme exists to stop.
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

    private func add(button title: String, action: Selector, primary: Bool = true) {
        body.addArrangedSubview(PillButton(title: title,
                                           emphasis: primary ? .primary : .secondary,
                                           tint: Theme.Colour.brass,
                                           target: self, action: action))
    }

    private func megabytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_000_000
        return mb >= 1000 ? String(format: "%.1f GB", mb / 1000)
                          : String(format: "%.0f MB", mb)
    }

    private func place(_ window: NSWindow) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                      y: visible.midY - size.height / 2
                                        + visible.height * 0.08))
    }

    private func raise(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}
