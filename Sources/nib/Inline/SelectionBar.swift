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
    var onRewrite: ((RewriteMode) async throws -> RewriteOutcome)?
    var onAccept: ((String) -> Void)?
    /// Counts the mistakes in the selection. Separate from `onRewrite` because
    /// it is a different engine answering a different question, and it answers
    /// two orders of magnitude faster.
    var onScore: (() async -> WritingScore?)?

    private let glyph = NSImageView()
    /// How many mistakes are in the selection, shown before any rewrite.
    private let scoreLabel = NSTextField(labelWithString: "")
    private lazy var diffButton = PillButton(
        title: "Diff", emphasis: .secondary, icon: "plusminus",
        iconTint: Theme.Colour.accept, target: self, action: #selector(toggleDiff))
    /// Whether the proposal is currently shown as a diff.
    private var showingDiff = false
    private let dots = LoadingDots()
    private let status = NSTextField(labelWithString: "")
    private let proposalView = ProposalView()
    private var modeButtons: [PillButton] = []
    private var proposal: String?
    /// Which mode produced what is on screen, so changing the dial can ask the
    /// same question again rather than leaving a stale answer or none at all.
    private var lastMode: RewriteMode?
    private var autoTask: Task<Void, Never>?
    private var scoreTask: Task<Void, Never>?
    /// The selected text, used to tell a real suggestion from an echo of the
    /// input.
    private var original = ""

    /// Set once the bar has been dragged, so it stops being re-anchored.
    ///
    /// Moving somewhere and being put back on the next redraw is worse than
    /// not being movable at all. Cleared when the bar goes away, so a fresh
    /// selection is offered above itself as usual rather than wherever the
    /// last one happened to be left.
    private var wasMoved = false
    /// True while nib is doing the moving, so its own frame changes are not
    /// mistaken for the user's.
    private var isPositioning = false

    /// The selected text, in screen coordinates. What the bar must not cover.
    private var anchor: CGRect = .zero
    /// Which side of the selection the bar settled on, so that growing to fit
    /// a proposal moves it away from the text rather than over it.
    private var placedAbove = true

    private enum Gap {
        static let fromText: CGFloat = 8
        static let fromScreen: CGFloat = 6
    }

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
        // Drag it anywhere by its background. The bar sits above the selection
        // by default, which is the right place until it covers the very line
        // being rewritten -- and then only the reader knows where it should go.
        isMovableByWindowBackground = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowMoved),
            name: NSWindow.didMoveNotification, object: self)
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
        status.textColor = Theme.Colour.inkMuted
        status.isHidden = true

        dots.isHidden = true

        // The proposal is the button. Clicking the text applies it, so what
        // you agree to and what you click are the same thing.
        proposalView.wrapWidth = Metrics.maxWidth - Theme.Space.edge * 2 - 40
        proposalView.isHidden = true
        proposalView.onAccept = { [weak self] in self?.accept() }
        proposalView.onToggleExpanded = { [weak self] in self?.resize() }

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

        // The strength dial that used to sit here is gone. It asked how far a
        // rewrite may stray, which is a question you cannot answer about a
        // sentence you already know is wrong -- and the answer people wanted
        // was always the boldest one, which is now what every rewrite does.

        // Only useful once there is a proposal, so it stays out of the way
        // until then.
        diffButton.isHidden = true
        diffButton.toolTip = "Show what this changes"

        scoreLabel.font = Theme.Font.caption
        scoreLabel.textColor = Theme.Colour.inkMuted
        scoreLabel.isHidden = true
        scoreLabel.toolTip = "Spelling, grammar and punctuation mistakes Harper "
            + "found. It does not judge whether the writing sounds natural."

        let actionRow = NSStackView(views: [
            glyph, modeRow, diffButton, scoreLabel, dots, status, NSView(),
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
        anchor = rect
        reset()
        resize(animated: false)

        // Already put somewhere deliberately: stay there.
        if reappearing, wasMoved {
            runAutomatically()
            return
        }

        let target = NSRect(origin: origin(for: frame.size), size: frame.size)

        isPositioning = true
        if reappearing {
            setFrame(target, display: true)
        } else {
            Theme.present(self, at: target)
            staggerButtons()
        }
        isPositioning = false

        // The count comes first and separately. Harper answers in about 30ms
        // against the model's second or more, so waiting for the rewrite to
        // show it would hide the fast answer behind the slow one.
        runScore()

        // Offer something without being asked. A bar of three buttons is a
        // menu; having the suggestion already there is the point.
        runAutomatically()
    }

    /// Counts the mistakes in the selection and shows the number.
    private func runScore() {
        scoreLabel.isHidden = true
        scoreTask?.cancel()
        guard let onScore else { return }

        scoreTask = Task { @MainActor [weak self] in
            let score = await onScore()
            guard !Task.isCancelled, let self, let score, score.words > 0 else {
                return
            }
            self.scoreLabel.stringValue = score.summary
            self.scoreLabel.textColor = Self.colour(for: score.standing)
            self.scoreLabel.isHidden = false
            self.resize()
        }
    }

    static func colour(for standing: WritingScore.Standing) -> NSColor {
        switch standing {
        case .clean: return Theme.Colour.accept
        case .few: return Theme.Colour.inkMuted
        case .many: return Theme.Colour.correction
        }
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
        status.textColor = Theme.Colour.inkMuted
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
            // Kept apart from "nothing to change". A refusal means a rewrite
            // was produced and rejected for changing the meaning, which is the
            // opposite of the writing being fine -- and reporting it as
            // "looks good" is exactly what sent someone looking for a bug.
            var refusal: String?

            for mode in [RewriteMode.fixGrammar, .clearer, .native] {
                guard !Task.isCancelled, let self else { return }
                let outcome: RewriteOutcome
                do {
                    outcome = try await onRewrite(mode)
                } catch {
                    failure = error
                    continue
                }
                guard !Task.isCancelled else { return }

                switch outcome {
                case .rewritten(let result) where !result.isEmpty:
                    self.present(proposal: result)
                    return
                case .refused(let why):
                    refusal = refusal ?? why
                case .rewritten, .unchanged:
                    continue
                }
            }
            guard !Task.isCancelled else { return }
            if let failure {
                self?.showFailure(failure)
            } else if let refusal {
                self?.show(status: refusal, tint: Theme.Colour.correction)
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
        Log.write("selection rewrite failed: \(error)")
        show(status: Self.message(for: error), tint: .systemRed)
    }

    /// Turns a rewrite failure into the line shown in the bar.
    ///
    /// Static and nonisolated so every case can be checked without building a
    /// window. The default branch is a last resort: anything reaching it is a
    /// failure nib knows about and is describing as though it does not.
    static func message(for error: Error) -> String {
        switch error {
        case RewriteError.modelMissing:
            return "no model installed"
        case RewriteError.serverFailed:
            return "model would not start"
        case RewriteError.badResponse:
            return "model gave no answer"
        // Out of memory is the one failure with an obvious cause and an
        // obvious fix, and it was landing in the default branch -- telling
        // someone with a working model that it was "unavailable". Dictation
        // makes this common: whisper holds its GPU memory for 180 seconds
        // after transcribing, so a rewrite in that window can fail purely
        // because the two are sharing a card.
        case RewriteError.outOfMemory:
            return "not enough memory -- try again in a moment"
        case RewriteError.rejected(let status, _):
            return "model refused (\(status))"
        default:
            return "model unavailable"
        }
    }


    @objc private func toggleDiff() {
        guard let proposal else { return }
        showingDiff.toggle()
        if showingDiff {
            proposalView.show(DiffText.attributed(from: original, to: proposal))
            diffButton.title = "Result"
            diffButton.toolTip = "Show the finished text"
        } else {
            proposalView.text = proposal
            diffButton.title = "Diff"
            diffButton.toolTip = "Show what this changes"
        }
        resize()
    }

    private func present(proposal text: String) {
        proposal = text
        // A new proposal is a new set of changes, so the view goes back to
        // showing the result rather than a diff of the previous one.
        showingDiff = false
        diffButton.title = "Diff"
        diffButton.isHidden = false
        proposalView.text = text
        // Roughly four lines' worth at this width; the chevron only appears
        // when there is something hidden behind it.
        proposalView.updateExpander(fits: text.count < 190)
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

    @objc private func windowMoved() {
        guard !isPositioning else { return }
        // The flag alone is not enough: present() and resize() animate, so
        // their frame changes land after it has been cleared and would read as
        // a drag. A drag has the mouse button held down; an animation does not.
        guard NSEvent.pressedMouseButtons & 1 == 1 else { return }
        wasMoved = true
        Log.write("selection bar moved by hand")
    }

    func dismiss() {
        autoTask?.cancel()
        wasMoved = false
        // Forgotten with the selection it belonged to. Otherwise moving the
        // dial against a fresh selection would rerun whatever the last one
        // asked for, unprompted.
        lastMode = nil
        guard isVisible else { return }
        dots.stop()
        Theme.dismiss(self)
    }

    private func reset() {
        autoTask?.cancel()
        proposal = nil
        showingDiff = false
        diffButton.isHidden = true
        diffButton.title = "Diff"
        proposalView.isHidden = true
        proposalView.text = ""
        status.isHidden = true
        dots.stop()
        modeButtons.forEach { $0.isEnabled = true }
    }

    /// Where the bar should sit so it covers as little of the selection as
    /// possible.
    ///
    /// Above by default, because a reader's eye is already at the end of what
    /// they selected. Below when there is not enough room above -- and the
    /// choice is made against the height it is about to be, not the height it
    /// is now, since the bar grows once a proposal arrives.
    private func origin(for size: NSSize) -> CGPoint {
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) }
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? anchor

        let roomAbove = visible.maxY - anchor.maxY
        let roomBelow = anchor.minY - visible.minY
        let needed = size.height + Gap.fromText + Gap.fromScreen

        // Whichever side fits. If neither does, the one with more room, since
        // covering part of the selection beats hanging off the screen.
        placedAbove = roomAbove >= needed || roomAbove >= roomBelow

        var point = CGPoint(
            x: anchor.midX - size.width / 2,
            y: placedAbove
                ? anchor.maxY + Gap.fromText
                : anchor.minY - size.height - Gap.fromText)

        point.x = min(max(point.x, visible.minX + Gap.fromScreen),
                      visible.maxX - size.width - Gap.fromScreen)
        point.y = min(max(point.y, visible.minY + Gap.fromScreen),
                      visible.maxY - size.height - Gap.fromScreen)
        return point
    }

    private func resize(animated: Bool = true) {
        isPositioning = true
        defer { isPositioning = false }
        contentView?.layoutSubtreeIfNeeded()
        let fitting = contentView?.fittingSize ?? NSSize(width: Metrics.minWidth, height: 36)
        let width = min(max(Metrics.minWidth, fitting.width), Metrics.maxWidth)
        let size = NSSize(width: width, height: ceil(fitting.height))

        // Dragged somewhere on purpose, or no selection to avoid: grow from the
        // top edge as before and leave the position alone.
        guard !wasMoved, anchor != .zero else {
            Theme.resize(self, to: size, animated: animated)
            return
        }

        // Growing to fit a proposal must move the bar away from the text, not
        // over it. Pinning the top edge -- which is right for a panel below the
        // selection -- grows a panel above it straight down onto the words it
        // is about.
        let target = NSRect(origin: origin(for: size), size: size)
        guard animated, isVisible else {
            setFrame(target, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.Motion.content
            context.timingFunction = Theme.Motion.easeOut
            animator().setFrame(target, display: true)
        }
    }

    // MARK: - Actions


    @objc private func runMode(_ sender: NSButton) {
        guard sender.tag < RewriteMode.allCases.count else { return }
        run(RewriteMode.allCases[sender.tag])
    }

    private func run(_ mode: RewriteMode) {
        guard let onRewrite else { return }
        autoTask?.cancel()
        lastMode = mode

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
                switch try await onRewrite(mode) {
                case .rewritten(let result) where !result.isEmpty:
                    self.present(proposal: result)
                case .rewritten, .unchanged:
                    self.show(status: "nothing to change", tint: Theme.Colour.inkMuted)
                case .refused(let why):
                    // Asked for explicitly, so the reason is owed. Silently
                    // handing back the original reads as the button not working.
                    self.show(status: why, tint: Theme.Colour.correction)
                }
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
