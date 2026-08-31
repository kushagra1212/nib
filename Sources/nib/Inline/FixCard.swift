import AppKit

/// The suggestion card, modelled on Grammarly's.
///
/// Anatomy, in order down the card:
///   1. an explanation of what is wrong, in muted text
///   2. the change read as a sentence: the old wording struck through in red,
///      the new wording in bold green, so the result is legible in place
///   3. one primary Accept, a quiet Dismiss, and arrows to walk the issues
///
/// The previous version listed each replacement as a separate button, which
/// asks the reader to work out what the sentence becomes. Showing the edit
/// itself means there is nothing to work out.
final class FixCard: NSPanel {
    var onAccept: ((Suggestion, String) -> Void)?
    var onDismiss: ((Suggestion) -> Void)?
    var onStep: ((Int) -> Void)?

    private(set) var isMouseInside = false

    private let explanation = NSTextField(labelWithString: "")
    private let diff = NSTextField(labelWithString: "")
    private let acceptButton = PillButton()
    private let dismissButton = PillButton()
    private let previousButton = PillButton()
    private let nextButton = PillButton()
    private let counter = NSTextField(labelWithString: "")

    private var suggestion: Suggestion?
    private var replacement: String?

    private enum Style {
        static let width: CGFloat = 360
        static let padding: CGFloat = 14
        static let corner: CGFloat = 10
        static let removed = Theme.Colour.removed
        static let added = Theme.Colour.added
        /// Motion is kept under a fifth of a second: perceptible, never a wait.
        static let appearDuration: TimeInterval = 0.14
        static let dismissDuration: TimeInterval = 0.10
        /// How far the card rises as it fades in.
        static let rise: CGFloat = 6
    }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Style.width, height: 120),
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

        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = Theme.Colour.inkMuted
        explanation.lineBreakMode = .byWordWrapping
        explanation.maximumNumberOfLines = 2
        explanation.preferredMaxLayoutWidth = Style.width - Style.padding * 2

        diff.font = .systemFont(ofSize: 14)
        diff.lineBreakMode = .byWordWrapping
        diff.maximumNumberOfLines = 4
        diff.preferredMaxLayoutWidth = Style.width - Style.padding * 2

        acceptButton.configure(title: "Accept", emphasis: .primary,
                               tint: Style.added, target: self,
                               action: #selector(accept))
        acceptButton.keyEquivalent = "\r"

        dismissButton.configure(title: "Dismiss", emphasis: .plain,
                                target: self, action: #selector(dismissTapped))

        configureStepper(previousButton, symbol: "chevron.left", action: #selector(stepBack))
        configureStepper(nextButton, symbol: "chevron.right", action: #selector(stepForward))

        counter.font = .systemFont(ofSize: 11)
        counter.textColor = Theme.Colour.inkMuted

        let actions = NSStackView(views: [
            acceptButton, dismissButton, NSView(),
            counter, previousButton, nextButton,
        ])
        actions.orientation = .horizontal
        actions.spacing = 6
        actions.alignment = .centerY

        let stack = NSStackView(views: [explanation, diff, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: Style.padding, left: Style.padding,
                                        bottom: Style.padding, right: Style.padding)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            actions.widthAnchor.constraint(
                equalToConstant: Style.width - Style.padding * 2),
        ])
    }

    private func configureStepper(_ button: PillButton, symbol: String, action: Selector) {
        button.configure(title: "", emphasis: .plain, target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageOnly
        button.contentTintColor = Theme.Colour.inkMuted
    }

    // MARK: - Content

    /// Shows one suggestion, anchored under the word it refers to.
    ///
    /// `context` is the surrounding sentence, used so the edit can be read in
    /// place rather than as two bare words.
    func show(
        _ suggestion: Suggestion,
        context: String,
        index: Int,
        total: Int,
        below anchor: CGPoint
    ) {
        // No replacement is a valid state: harper flags plenty it cannot fix
        // automatically. The card then explains the problem and offers only
        // Dismiss, rather than refusing to appear.
        let replacement = suggestion.replacements.first

        if self.suggestion?.id != suggestion.id {
            self.suggestion = suggestion
            self.replacement = replacement
            // Says where the advice came from. Harper matched a dictionary and
            // a rule set; the model wrote a sentence and nib diffed it. Those
            // do not deserve the same confidence, and the card is where the
            // decision to accept is actually made.
            explanation.attributedStringValue = Self.explanationText(
                suggestion.message, source: suggestion.source)

            if let replacement {
                // A clarity suggestion replaces a whole sentence, so a
                // word-level diff with surrounding context would repeat most
                // of it twice. Show the rewritten sentence on its own instead.
                diff.attributedStringValue = suggestion.kind == .clarity
                    ? Self.clarityText(replacement)
                    : Self.diffText(suggestion, replacement: replacement, context: context)
                diff.isHidden = false
                acceptButton.isHidden = false
                // Accept carries the colour of what it is accepting, so the
                // card reads as one thing rather than a red mark with a green
                // button stuck on it.
                acceptButton.configure(
                    title: "Accept", emphasis: .primary,
                    tint: suggestion.kind == .clarity
                        ? Theme.Colour.clarity : Theme.Colour.accept,
                    target: self, action: #selector(accept))
                acceptButton.keyEquivalent = "\r"
            } else {
                // No fix to accept, so no Accept button -- and the card has to
                // say that. A missing button reads as a broken card, and this
                // state is common: harper flags plenty it cannot fix, and a
                // word whose every suggested fix was rejected as damage keeps
                // its mark and arrives here with nothing to offer.
                diff.attributedStringValue = Self.noFixText()
                diff.isHidden = false
                acceptButton.isHidden = true
            }

            counter.stringValue = total > 1 ? "\(index + 1) of \(total)" : ""
            previousButton.isHidden = total <= 1
            nextButton.isHidden = total <= 1
            counter.isHidden = total <= 1

            layoutIfNeeded()
            let fitting = contentView?.fittingSize ?? NSSize(width: Style.width, height: 120)
            setContentSize(NSSize(width: Style.width, height: ceil(fitting.height)))
        }

        let wasVisible = isVisible
        position(below: anchor)

        if wasVisible {
            orderFront(nil)
        } else {
            appear()
        }
    }

    /// Fades and lifts the card into place.
    ///
    /// Short and eased-out: long enough to read as motion rather than a flash,
    /// short enough that it never delays reaching the buttons. The rise is a
    /// few points only, so the card does not appear to travel.
    private func appear() {
        alphaValue = 0
        var target = frame
        let lifted = NSRect(x: target.origin.x, y: target.origin.y - Style.rise,
                            width: target.width, height: target.height)
        setFrame(lifted, display: false)
        orderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Style.appearDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            animator().alphaValue = 1
            animator().setFrame(target, display: true)
        }
        target = frame
    }

    /// Fades out, then orders out once invisible.
    func dismiss() {
        guard isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Style.dismissDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.alphaValue < 0.05 else { return }
            self.orderOut(nil)
            self.alphaValue = 1
        }
    }

    /// The message, with a small tag when the model wrote it.
    ///
    /// A tag rather than a separate row: it belongs to the sentence explaining
    /// the change, and a whole line of chrome for one word would crowd a card
    /// that has to stay small enough to float over someone's text.
    static func explanationText(
        _ message: String, source: SuggestionSource
    ) -> NSAttributedString {
        let out = NSMutableAttributedString()
        if source == .model { out.append(Theme.aiTag()) }
        out.append(NSAttributedString(string: message, attributes: [
            .foregroundColor: Theme.Colour.inkMuted,
            .font: NSFont.systemFont(ofSize: 12),
        ]))
        return out
    }

    /// Stands in for the diff when there is no fix to show.
    ///
    /// Said plainly, because the alternative is a card with the Accept button
    /// missing and no reason given, which looks like the card failed rather
    /// than like nib having nothing to offer.
    static func noFixText() -> NSAttributedString {
        NSAttributedString(string: "No suggested fix — flagged only.", attributes: [
            .foregroundColor: Theme.Colour.inkMuted,
            .font: NSFont.systemFont(ofSize: 13),
        ])
    }

    /// The proposed sentence, shown plainly.
    static func clarityText(_ replacement: String) -> NSAttributedString {
        NSAttributedString(string: replacement, attributes: [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.systemFont(ofSize: 14),
        ])
    }

    /// Builds "old new" with the old struck through and the new in bold green,
    /// padded with a little of the surrounding sentence for context.
    static func diffText(
        _ suggestion: Suggestion, replacement: String, context: String
    ) -> NSAttributedString {
        let ns = context as NSString
        let range = suggestion.range
        guard NSMaxRange(range) <= ns.length else {
            return NSAttributedString(string: replacement)
        }

        let original = ns.substring(with: range)
        let out = NSMutableAttributedString()

        // A short run-up so the edit reads as part of the sentence. Cut at a
        // word boundary; slicing mid-word reads as a second error.
        let leadStart = max(0, range.location - 28)
        var lead = ns.substring(with: NSRange(location: leadStart,
                                              length: range.location - leadStart))
        if leadStart > 0, let space = lead.firstIndex(of: " ") {
            lead = "…" + String(lead[space...])
        }
        if !lead.isEmpty {
            out.append(NSAttributedString(string: lead, attributes: [
                .foregroundColor: NSColor.labelColor,
                .font: NSFont.systemFont(ofSize: 14),
            ]))
        }

        out.append(NSAttributedString(string: original, attributes: [
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .strikethroughColor: Style.removed,
            .foregroundColor: Style.removed,
            .font: NSFont.systemFont(ofSize: 14),
        ]))
        out.append(NSAttributedString(string: " "))
        out.append(NSAttributedString(string: replacement, attributes: [
            .foregroundColor: Style.added,
            .font: NSFont.boldSystemFont(ofSize: 14),
        ]))

        let tailEnd = min(ns.length, NSMaxRange(range) + 24)
        var tail = ns.substring(with: NSRange(location: NSMaxRange(range),
                                              length: tailEnd - NSMaxRange(range)))
        if tailEnd < ns.length, let space = tail.lastIndex(of: " ") {
            tail = String(tail[..<space]) + "…"
        }
        if !tail.isEmpty {
            out.append(NSAttributedString(string: tail, attributes: [
                .foregroundColor: NSColor.labelColor,
                .font: NSFont.systemFont(ofSize: 14),
            ]))
        }
        return out
    }

    private func position(below anchor: CGPoint) {
        var origin = CGPoint(x: anchor.x - 8, y: anchor.y - frame.height - 8)
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 6), visible.maxX - frame.width - 6)
            // No room beneath the word: sit above it rather than off-screen.
            if origin.y < visible.minY + 6 { origin.y = anchor.y + 20 }
        }
        setFrameOrigin(origin)
    }

    // MARK: - Actions

    @objc private func accept() {
        guard let suggestion, let replacement else { return }
        onAccept?(suggestion, replacement)
    }

    @objc private func dismissTapped() {
        guard let suggestion else { return }
        onDismiss?(suggestion)
    }

    @objc private func stepBack() { onStep?(-1) }
    @objc private func stepForward() { onStep?(1) }

    override func mouseEntered(with event: NSEvent) { isMouseInside = true }
    override func mouseExited(with event: NSEvent) { isMouseInside = false }

    /// Clears state so the next show() rebuilds rather than reusing content.
    func reset() {
        suggestion = nil
        replacement = nil
    }
}
