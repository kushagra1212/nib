import AppKit

/// A small bar that appears above selected text offering rewrites.
///
/// Selecting a phrase and being offered something is the interaction people
/// expect, and it previously required a hotkey and a full panel.
///
/// Two states, and the transition between them is the point: a row of actions,
/// then the proposed text with a Replace button. The result is always shown
/// before it is applied, because a small model can produce something worse
/// than the original and swapping text out unseen is not a fair trade.
final class SelectionBar: NSPanel {
    var onRewrite: ((RewriteMode) async throws -> String)?
    var onAccept: ((String) -> Void)?

    private let glyph = NSImageView()
    private let dots = LoadingDots()
    private let status = NSTextField(labelWithString: "")
    private let preview = NSTextField(labelWithString: "")
    private let previewBox = NSView()
    private var modeButtons: [PillButton] = []
    private var acceptButton: PillButton!
    private var proposal: String?

    private enum Metrics {
        static let maxWidth: CGFloat = 440
        static let minWidth: CGFloat = 210
    }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Metrics.minWidth, height: 36),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        build()
    }

    override var canBecomeKey: Bool { false }

    private func build() {
        let background = Theme.makeBackground()
        contentView = background

        // A mark of whose bar this is, so it is not mistaken for the host app.
        glyph.image = NSImage(systemSymbolName: "pencil.line",
                              accessibilityDescription: "nib")
        glyph.contentTintColor = .tertiaryLabelColor
        glyph.imageScaling = .scaleProportionallyUpOrDown

        status.font = Theme.Font.caption
        status.textColor = .secondaryLabelColor
        status.isHidden = true

        dots.isHidden = true

        // The proposed text, in its own tinted well so it reads as a quotation
        // rather than as more chrome.
        preview.font = Theme.Font.body
        preview.textColor = .labelColor
        preview.lineBreakMode = .byWordWrapping
        preview.maximumNumberOfLines = 4
        preview.preferredMaxLayoutWidth = Metrics.maxWidth - Theme.Space.edge * 2 - 16
        preview.translatesAutoresizingMaskIntoConstraints = false

        previewBox.wantsLayer = true
        previewBox.layer?.cornerRadius = Theme.Radius.control
        previewBox.layer?.cornerCurve = .continuous
        previewBox.layer?.backgroundColor = NSColor.controlColor
            .withAlphaComponent(0.35).cgColor
        previewBox.addSubview(preview)
        previewBox.isHidden = true

        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor, constant: 8),
            preview.trailingAnchor.constraint(equalTo: previewBox.trailingAnchor, constant: -8),
            preview.topAnchor.constraint(equalTo: previewBox.topAnchor, constant: 6),
            preview.bottomAnchor.constraint(equalTo: previewBox.bottomAnchor, constant: -6),
        ])

        let modeRow = NSStackView()
        modeRow.orientation = .horizontal
        modeRow.spacing = Theme.Space.tight
        for (index, mode) in RewriteMode.allCases.enumerated() {
            let button = PillButton(title: mode.shortTitle, emphasis: .secondary,
                                    target: self, action: #selector(runMode(_:)))
            button.tag = index
            modeButtons.append(button)
            modeRow.addArrangedSubview(button)
        }

        acceptButton = PillButton(title: "Replace", emphasis: .primary,
                                  tint: Theme.Colour.accept,
                                  target: self, action: #selector(accept))
        acceptButton.isHidden = true

        let actionRow = NSStackView(views: [
            glyph, modeRow, dots, status, NSView(), acceptButton,
        ])
        actionRow.orientation = .horizontal
        actionRow.spacing = Theme.Space.row
        actionRow.alignment = .centerY

        let root = NSStackView(views: [previewBox, actionRow])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = Theme.Space.row
        root.edgeInsets = NSEdgeInsets(top: Theme.Space.row, left: Theme.Space.edge,
                                       bottom: Theme.Space.row, right: Theme.Space.edge)
        root.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            root.topAnchor.constraint(equalTo: background.topAnchor),
            root.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 13),
            glyph.heightAnchor.constraint(equalToConstant: 13),
        ])
    }

    // MARK: - Presentation

    func present(above rect: CGRect) {
        let reappearing = isVisible
        reset()
        resize(animated: false)

        var origin = CGPoint(x: rect.midX - frame.width / 2, y: rect.maxY + 8)
        let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 6), visible.maxX - frame.width - 6)
            // No room above the selection: sit below it instead.
            if origin.y + frame.height > visible.maxY - 6 {
                origin.y = rect.minY - frame.height - 8
            }
        }
        let target = NSRect(origin: origin, size: frame.size)

        if reappearing {
            setFrame(target, display: true)
        } else {
            Theme.present(self, at: target)
            staggerButtons()
        }
    }

    /// Fades the actions in one after another, so the bar assembles rather
    /// than arriving fully formed.
    private func staggerButtons() {
        for (index, button) in modeButtons.enumerated() {
            guard let layer = button.layer else { continue }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.18
            fade.beginTime = CACurrentMediaTime() + Double(index) * 0.045
            fade.fillMode = .backwards
            fade.timingFunction = Theme.Motion.easeOut
            layer.add(fade, forKey: "stagger")
        }
    }

    func dismiss() {
        guard isVisible else { return }
        dots.stop()
        Theme.dismiss(self)
    }

    private func reset() {
        proposal = nil
        previewBox.isHidden = true
        preview.stringValue = ""
        acceptButton.isHidden = true
        status.isHidden = true
        dots.stop()
        modeButtons.forEach { $0.isEnabled = true }
    }

    private func resize(animated: Bool = true) {
        contentView?.layoutSubtreeIfNeeded()
        let fitting = contentView?.fittingSize ?? NSSize(width: Metrics.minWidth, height: 36)
        let width = min(max(Metrics.minWidth, fitting.width), Metrics.maxWidth)
        Theme.resize(self, to: NSSize(width: width, height: ceil(fitting.height)),
                     animated: animated)
    }

    // MARK: - Actions

    @objc private func runMode(_ sender: NSButton) {
        guard let onRewrite, sender.tag < RewriteMode.allCases.count else { return }
        let mode = RewriteMode.allCases[sender.tag]

        modeButtons.forEach { $0.isEnabled = false }
        previewBox.isHidden = true
        acceptButton.isHidden = true
        status.stringValue = mode.shortTitle.lowercased()
        status.isHidden = false
        dots.start()
        resize()

        Task { @MainActor in
            defer {
                self.modeButtons.forEach { $0.isEnabled = true }
                self.dots.stop()
            }
            do {
                let result = try await onRewrite(mode)
                guard !result.isEmpty else {
                    self.show(status: "nothing to change", tint: .secondaryLabelColor)
                    return
                }
                self.proposal = result
                self.preview.stringValue = result
                self.previewBox.isHidden = false
                self.acceptButton.isHidden = false
                self.status.isHidden = true
                self.resize()
                self.revealPreview()
            } catch {
                self.show(status: "needs a model", tint: .systemOrange)
            }
        }
    }

    private func show(status text: String, tint: NSColor) {
        status.stringValue = text
        status.textColor = tint
        status.isHidden = false
        resize()
    }

    /// Slides the proposal down into place as the bar grows to fit it.
    private func revealPreview() {
        guard let layer = previewBox.layer else { return }
        let slide = CABasicAnimation(keyPath: "transform.translation.y")
        slide.fromValue = 6
        slide.toValue = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1

        let group = CAAnimationGroup()
        group.animations = [slide, fade]
        group.duration = Theme.Motion.content
        group.timingFunction = Theme.Motion.easeOut
        layer.add(group, forKey: "reveal")
    }

    @objc private func accept() {
        guard let proposal else { return }
        onAccept?(proposal)
        dismiss()
    }
}
