import AppKit

/// A small bar that appears above selected text offering rewrites.
///
/// Selecting a phrase and being offered something is the interaction people
/// expect, and it previously required a hotkey and a full panel.
///
/// Two states, and the transition between them is the point: a row of actions,
/// then the proposal itself, which is what you click to accept. The result is
/// always shown before it is applied, because a small model can produce
/// something worse than the original and swapping text out unseen is not a
/// fair trade.
final class SelectionBar: NSPanel {
    var onRewrite: ((RewriteMode) async throws -> String)?
    var onAccept: ((String) -> Void)?

    private let glyph = NSImageView()
    private let strengthDial = NSSegmentedControl()
    private let dots = LoadingDots()
    private let status = NSTextField(labelWithString: "")
    private let proposalView = ProposalView()
    private var modeButtons: [PillButton] = []
    private var proposal: String?
    private var autoTask: Task<Void, Never>?
    /// The selected text, used to tell a real suggestion from an echo of the
    /// input.
    private var original = ""

    /// Set by the owner before presenting.
    func prepare(original text: String) {
        self.original = text
    }

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
        glyph.image = NSImage(systemSymbolName: "sparkles",
                              accessibilityDescription: "nib")
        glyph.contentTintColor = Theme.Colour.rewrite.withAlphaComponent(0.85)
        glyph.imageScaling = .scaleProportionallyUpOrDown

        status.font = Theme.Font.caption
        status.textColor = .secondaryLabelColor
        status.isHidden = true

        dots.isHidden = true

        // The proposal is the button. Clicking the text applies it, so what
        // you agree to and what you click are the same thing.
        proposalView.wrapWidth = Metrics.maxWidth - Theme.Space.edge * 2 - 40
        proposalView.isHidden = true
        proposalView.onAccept = { [weak self] in self?.accept() }

        let modeRow = NSStackView()
        modeRow.orientation = .horizontal
        modeRow.spacing = Theme.Space.tight
        for (index, mode) in RewriteMode.allCases.enumerated() {
            let button = PillButton(title: mode.shortTitle, emphasis: .secondary,
                                    icon: mode.icon, iconTint: mode.iconTint,
                                    target: self,
                                    action: #selector(runMode(_:)))
            button.tag = index
            modeButtons.append(button)
            modeRow.addArrangedSubview(button)
        }

        // How far any of those four may travel. Its own control rather than
        // more buttons: the mode is what you want done, the dial is how much,
        // and folding twelve combinations into one row would read as twelve
        // unrelated actions.
        strengthDial.segmentStyle = .rounded
        strengthDial.segmentCount = RewriteStrength.allCases.count
        strengthDial.controlSize = .small
        strengthDial.font = Theme.Font.control
        strengthDial.target = self
        strengthDial.action = #selector(strengthChanged)
        for (index, strength) in RewriteStrength.allCases.enumerated() {
            strengthDial.setLabel(strength.title, forSegment: index)
            if strength == RewriteStrength.current {
                strengthDial.selectedSegment = index
            }
        }
        strengthDial.toolTip = "How far a rewrite may stray from what you wrote"

        let actionRow = NSStackView(views: [
            glyph, modeRow, strengthDial, dots, status, NSView(),
        ])
        actionRow.orientation = .horizontal
        actionRow.spacing = Theme.Space.row
        actionRow.alignment = .centerY

        let root = NSStackView(views: [proposalView, actionRow])
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

        // Offer something without being asked. A bar of three buttons is a
        // menu; having the suggestion already there is the point.
        runAutomatically()
    }

    /// Produces a first suggestion as soon as the bar appears.
    ///
    /// Fix runs first because a correction is the higher-confidence answer. If
    /// the text is already correct that returns the input unchanged, which is
    /// no use as a suggestion, so Clearer follows and offers a rewrite
    /// instead. Both are cached, so pressing the matching button afterwards is
    /// instant.
    private func runAutomatically() {
        guard let onRewrite else { return }
        autoTask?.cancel()

        modeButtons.forEach { $0.isEnabled = false }
        status.stringValue = "reading"
        status.textColor = .secondaryLabelColor
        status.isHidden = false
        dots.start()
        resize()

        autoTask = Task { @MainActor [weak self] in
            defer {
                self?.modeButtons.forEach { $0.isEnabled = true }
                self?.dots.stop()
            }
            // Kept so a failure can be told apart from a clean sentence. This
            // used to be `try?`, which threw the error away: with no model
            // installed both modes fell through to the end of the loop and the
            // bar reported "looks good" in green. Nothing had been checked.
            var failure: Error?

            for mode in [RewriteMode.fixGrammar, .clearer] {
                guard !Task.isCancelled, let self else { return }
                let result: String
                do {
                    result = try await onRewrite(mode)
                } catch {
                    failure = error
                    continue
                }
                guard !result.isEmpty else { continue }
                guard !Task.isCancelled else { return }
                // Unchanged text is not a suggestion; try the next mode.
                guard result.trimmingCharacters(in: .whitespacesAndNewlines)
                        != self.original.trimmingCharacters(in: .whitespacesAndNewlines)
                else { continue }

                self.present(proposal: result)
                return
            }
            guard !Task.isCancelled else { return }
            if let failure {
                self?.showFailure(failure)
            } else {
                self?.show(status: "looks good", tint: Theme.Colour.accept)
            }
        }
    }

    /// Names what went wrong, in red.
    ///
    /// "looks good" and "needs a model" are both claims about the writing.
    /// Neither is true when the model never ran, and green in particular reads
    /// as "checked, and clean" when nothing was checked at all.
    private func showFailure(_ error: Error) {
        let text: String
        switch error {
        case RewriteError.modelMissing:
            text = "no model installed"
        case RewriteError.serverFailed:
            text = "model would not start"
        case RewriteError.badResponse:
            text = "model gave no answer"
        default:
            text = "model unavailable"
        }
        Log.write("selection rewrite failed: \(error)")
        show(status: text, tint: .systemRed)
    }

    private func present(proposal text: String) {
        proposal = text
        proposalView.text = text
        proposalView.isHidden = false
        status.isHidden = true
        resize()
        revealPreview()
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
        autoTask?.cancel()
        guard isVisible else { return }
        dots.stop()
        Theme.dismiss(self)
    }

    private func reset() {
        autoTask?.cancel()
        proposal = nil
        proposalView.isHidden = true
        proposalView.text = ""
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

    @objc private func strengthChanged() {
        let index = strengthDial.selectedSegment
        guard RewriteStrength.allCases.indices.contains(index) else { return }
        let strength = RewriteStrength.allCases[index]
        RewriteStrength.current = strength
        Log.write("rewrite strength set to \(strength.rawValue)")

        // The proposal on screen was produced under the old setting, so it no
        // longer answers the question being asked.
        proposal = nil
        proposalView.isHidden = true
        status.isHidden = true
        resize()
    }

    @objc private func runMode(_ sender: NSButton) {
        guard let onRewrite, sender.tag < RewriteMode.allCases.count else { return }
        let mode = RewriteMode.allCases[sender.tag]
        autoTask?.cancel()

        modeButtons.forEach { $0.isEnabled = false }
        proposalView.isHidden = true
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
                self.present(proposal: result)
            } catch {
                // Was "needs a model" in orange for every failure, including a
                // server that crashed with the model sitting right there.
                self.showFailure(error)
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
        guard let layer = proposalView.layer else { return }
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

    private func accept() {
        guard let proposal else { return }
        onAccept?(proposal)
        dismiss()
    }
}
