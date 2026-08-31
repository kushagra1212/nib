import AppKit

/// The pill that shows dictation is happening.
///
/// A toggle can be forgotten, so this is not decoration: it is the only thing
/// standing between "recording" and "recording without realising". It appears
/// the instant the microphone opens and cannot be dismissed while it is live.
@MainActor
final class DictationOverlay {
    private var window: NSPanel?
    private var meter: LevelMeter?
    private var label: NSTextField?
    private var timer: Timer?

    /// Asked for the current level and elapsed time, 30 times a second.
    var sample: (() -> (level: Float, elapsed: TimeInterval))?
    var onCancel: (() -> Void)?

    // MARK: - Showing

    func show(_ state: DictationState) {
        switch state {
        case .recording:
            present(listening: true, text: "Listening")
        case .transcribing:
            present(listening: false, text: "Transcribing…")
        case .requestingAccess:
            present(listening: false, text: "Waiting for the microphone…")
        case .inserting, .idle, .failed:
            dismiss()
        }
    }

    private func present(listening: Bool, text: String) {
        let panel = window ?? build()
        window = panel

        label?.stringValue = text
        meter?.isHidden = !listening
        meter?.isActive = listening

        if !panel.isVisible {
            place(panel)
            Theme.present(panel, at: panel.frame)
        }
        startSampling(listening)
    }

    func dismiss() {
        timer?.invalidate()
        timer = nil
        meter?.isActive = false
        guard let window, window.isVisible else { return }
        Theme.dismiss(window)
    }

    // MARK: - Building

    private func build() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 210, height: 44),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered, defer: false)
        // Above everything, including full-screen apps. A recording indicator
        // that another window can cover is not an indicator.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .ignoresCycle]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        // Never takes focus: dictation is used while typing somewhere else,
        // and stealing key status would move the caret away from the field the
        // text is meant for.
        panel.becomesKeyOnlyIfNeeded = true

        let background = Theme.makeBackground()
        background.translatesAutoresizingMaskIntoConstraints = false

        let dot = LevelMeter()
        meter = dot

        let caption = NSTextField(labelWithString: "Listening")
        caption.font = Theme.Font.control
        caption.textColor = .secondaryLabelColor
        label = caption

        let stop = NSButton(title: "Stop", target: self, action: #selector(cancelled))
        stop.bezelStyle = .rounded
        stop.controlSize = .small
        stop.font = Theme.Font.control

        let row = NSStackView(views: [dot, caption, stop])
        row.spacing = 10
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(background)
        content.addSubview(row)
        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: content.topAnchor),
            background.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            background.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 14),
            dot.heightAnchor.constraint(equalToConstant: 14),
        ])
        panel.contentView = content
        return panel
    }

    /// Bottom centre of the screen holding the pointer, above the Dock.
    ///
    /// Away from the text being dictated into, which is usually where the user
    /// is looking, and off the menu bar, which is where nib's other surfaces
    /// live.
    private func place(_ panel: NSPanel) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                     y: visible.minY + 90))
    }

    private func startSampling(_ listening: Bool) {
        timer?.invalidate()
        guard listening else { return }
        // 30Hz: enough for the meter to track speech, cheap enough not to
        // matter next to the audio tap it is drawing.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let sample = self.sample?() else { return }
                self.meter?.level = sample.level
                self.label?.stringValue = Self.caption(for: sample.elapsed)
            }
        }
    }

    /// "Listening" until it has been a while, then the elapsed time -- which
    /// is the point at which someone might have forgotten they left it on.
    ///
    /// Nonisolated because it is a pure function of the time, and the rest of
    /// this class owning a window should not drag a string format onto the
    /// main actor to be tested.
    nonisolated static func caption(for elapsed: TimeInterval) -> String {
        guard elapsed >= 10 else { return "Listening" }
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        let remaining = AudioRecorder.maximumDuration - elapsed
        if remaining <= 60 {
            return String(format: "%d:%02d — stopping soon", minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    @objc private func cancelled() {
        onCancel?()
    }
}

/// A dot that grows and brightens with the voice.
///
/// Motion rather than a static red dot: a light that never changes says the
/// feature is on, where one that moves says it can hear you -- which is the
/// question someone actually has while dictating.
private final class LevelMeter: NSView {
    var isActive = false {
        didSet { needsDisplay = true }
    }

    var level: Float = 0 {
        didSet {
            // Rises immediately, falls slowly. A meter that tracks the signal
            // exactly flickers on every gap between words.
            smoothed = level > smoothed ? level : smoothed * 0.85 + level * 0.15
            needsDisplay = true
        }
    }

    private var smoothed: Float = 0

    override func draw(_ dirtyRect: NSRect) {
        guard isActive else { return }
        let scale = CGFloat(0.55 + min(1, smoothed) * 0.45)
        let size = bounds.width * scale
        let rect = NSRect(x: bounds.midX - size / 2, y: bounds.midY - size / 2,
                          width: size, height: size)
        NSColor.systemRed.withAlphaComponent(0.35 + CGFloat(smoothed) * 0.65)
            .setFill()
        NSBezierPath(ovalIn: rect).fill()
    }
}
