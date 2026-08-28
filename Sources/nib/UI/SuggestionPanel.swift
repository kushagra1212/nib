import AppKit

/// A small floating card, sized to its content.
///
/// Deliberately not a document window: no title bar, no traffic lights, no
/// fixed frame. It appears next to what you were typing, shows the few things
/// that are wrong, and gets out of the way. A large empty window for a
/// four-word sentence is the thing that made the first version feel wrong.
final class SuggestionPanel: NSPanel {
    private enum Metrics {
        static let width: CGFloat = 380
        static let padding: CGFloat = 12
        static let cornerRadius: CGFloat = 12
        /// Text area grows with the text, up to this, then scrolls.
        static let maxTextHeight: CGFloat = 120
        static let minTextHeight: CGFloat = 34
        static let rowHeight: CGFloat = 26
        /// More rows than this and the card stops being glanceable.
        static let maxVisibleRows = 4
    }

    private let textView = NSTextView()
    private let textScroll = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let rowsStack = NSStackView()
    private let overflowLabel = NSTextField(labelWithString: "")
    private var rewriteButtons: [NSButton] = []
    private let undoButton = NSButton()
    private var textHeight: NSLayoutConstraint!

    private var suggestions: [Suggestion] = []
    private var onApply: ((String) -> Void)?
    private var onRequestFixes: (([Suggestion]) async -> [Suggestion])?
    private var onRewrite: ((String, RewriteMode) async throws -> String)?
    private var textBeforeRewrite: String?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.width, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        buildLayout()
    }

    override var canBecomeKey: Bool { true }

    private func buildLayout() {
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = Metrics.cornerRadius
        background.layer?.masksToBounds = true
        contentView = background

        textView.isRichText = false
        textView.font = .systemFont(ofSize: 13)
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true

        textScroll.documentView = textView
        textScroll.drawsBackground = false
        textScroll.borderType = .noBorder
        textScroll.hasVerticalScroller = false
        textScroll.translatesAutoresizingMaskIntoConstraints = false
        textHeight = textScroll.heightAnchor.constraint(
            equalToConstant: Metrics.minTextHeight)
        textHeight.isActive = true

        // Rows go straight into the stack rather than a scroll view. The first
        // version nested them in an NSScrollView inside an NSSplitView, where
        // they collapsed to zero height and the fixes were unreachable.
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 2

        overflowLabel.font = .systemFont(ofSize: 10)
        overflowLabel.textColor = .tertiaryLabelColor
        overflowLabel.isHidden = true

        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor

        let rewriteRow = NSStackView()
        rewriteRow.orientation = .horizontal
        rewriteRow.spacing = 4
        for (index, mode) in RewriteMode.allCases.enumerated() {
            let button = NSButton(title: mode.shortTitle, target: self,
                                  action: #selector(rewriteTapped(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.tag = index
            rewriteButtons.append(button)
            rewriteRow.addArrangedSubview(button)
        }

        undoButton.title = "Undo"
        undoButton.bezelStyle = .rounded
        undoButton.controlSize = .small
        undoButton.font = .systemFont(ofSize: 11)
        undoButton.keyEquivalent = "z"
        undoButton.keyEquivalentModifierMask = .command
        undoButton.target = self
        undoButton.action = #selector(undoRewrite)
        undoButton.isHidden = true
        rewriteRow.addArrangedSubview(undoButton)
        rewriteRow.addArrangedSubview(NSView())

        let replace = NSButton(title: "Replace", target: self,
                               action: #selector(applyTapped))
        replace.bezelStyle = .rounded
        replace.controlSize = .small
        replace.keyEquivalent = "\r"

        let cancel = NSButton(title: "Esc", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        cancel.controlSize = .small
        cancel.keyEquivalent = "\u{1b}"

        let footer = NSStackView(views: [statusLabel, NSView(), cancel, replace])
        footer.orientation = .horizontal
        footer.spacing = 6

        let root = NSStackView(views: [
            textScroll, rowsStack, overflowLabel, rewriteRow, footer,
        ])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: Metrics.padding, left: Metrics.padding,
                                       bottom: Metrics.padding, right: Metrics.padding)
        root.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            root.topAnchor.constraint(equalTo: background.topAnchor),
            root.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            textScroll.widthAnchor.constraint(
                equalToConstant: Metrics.width - Metrics.padding * 2),
        ])
    }

    // MARK: - Presentation

    func present(
        text: String,
        near point: NSPoint?,
        onApply: @escaping (String) -> Void,
        requestFixes: @escaping ([Suggestion]) async -> [Suggestion],
        onRewrite: @escaping (String, RewriteMode) async throws -> String
    ) {
        self.onApply = onApply
        self.onRequestFixes = requestFixes
        self.onRewrite = onRewrite
        self.textBeforeRewrite = nil
        undoButton.isHidden = true

        textView.string = text
        suggestions = []
        renderRows()
        statusLabel.stringValue = "checking…"
        resize()
        position(near: point)

        orderFrontRegardless()
        makeKey()
    }

    /// Places the card near the caret, nudged fully on-screen.
    private func position(near point: NSPoint?) {
        guard let screen = NSScreen.main else { center(); return }
        guard let point else { center(); return }

        let size = frame.size
        var origin = NSPoint(x: point.x - 20, y: point.y - size.height - 20)
        let visible = screen.visibleFrame

        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        // Not enough room below the caret: flip above it rather than clipping.
        if origin.y < visible.minY + 8 {
            origin.y = point.y + 20
        }
        origin.y = min(origin.y, visible.maxY - size.height - 8)
        setFrameOrigin(origin)
    }

    func show(_ found: [Suggestion]) {
        suggestions = found
        decorate()
        statusLabel.stringValue = found.isEmpty
            ? "looks clean"
            : "\(found.count) issue\(found.count == 1 ? "" : "s")"
        renderRows()
        resize()

        guard let onRequestFixes, !found.isEmpty else { return }
        let visible = Array(found.prefix(Metrics.maxVisibleRows))
        Task { @MainActor in
            let filled = await onRequestFixes(visible)
            guard self.suggestions.count >= filled.count else { return }
            self.suggestions.replaceSubrange(0..<filled.count, with: filled)
            self.renderRows()
            self.resize()
        }
    }

    func showError(_ message: String) {
        statusLabel.stringValue = message
    }

    /// Grows the card to fit its content, within limits.
    private func resize() {
        layoutIfNeeded()

        let measured = textView.layoutManager?.usedRect(
            for: textView.textContainer!).height ?? Metrics.minTextHeight
        textHeight.constant = min(max(measured + 12, Metrics.minTextHeight),
                                  Metrics.maxTextHeight)
        textScroll.hasVerticalScroller = measured + 12 > Metrics.maxTextHeight

        layoutIfNeeded()
        let fitting = contentView?.fittingSize ?? NSSize(width: Metrics.width, height: 120)
        let target = NSSize(width: Metrics.width, height: ceil(fitting.height))

        // Grow downward from the top edge so the card does not jump around.
        var newFrame = frame
        newFrame.origin.y += newFrame.height - target.height
        newFrame.size = target
        setFrame(newFrame, display: true)
    }

    private func decorate() {
        guard let storage = textView.textStorage else { return }
        let whole = NSRange(location: 0, length: storage.length)
        storage.removeAttribute(.underlineStyle, range: whole)
        storage.removeAttribute(.underlineColor, range: whole)

        for suggestion in suggestions {
            guard NSMaxRange(suggestion.range) <= storage.length else { continue }
            storage.addAttributes([
                .underlineStyle: NSUnderlineStyle.thick.rawValue,
                .underlineColor: NSColor.systemRed,
            ], range: suggestion.range)
        }
    }

    private func renderRows() {
        rowsStack.arrangedSubviews.forEach {
            rowsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        for (index, suggestion) in suggestions.prefix(Metrics.maxVisibleRows).enumerated() {
            rowsStack.addArrangedSubview(makeRow(suggestion, index: index))
        }

        let hidden = suggestions.count - Metrics.maxVisibleRows
        overflowLabel.isHidden = hidden <= 0
        overflowLabel.stringValue = hidden > 0 ? "+\(hidden) more" : ""
    }

    /// One row: the wrong word, then its best fixes as buttons.
    private func makeRow(_ suggestion: Suggestion, index: Int) -> NSView {
        let excerpt = suggestion.excerpt(in: textView.string) ?? ""
        let word = NSTextField(labelWithString: excerpt)
        word.font = .systemFont(ofSize: 11, weight: .medium)
        word.textColor = .systemRed
        word.lineBreakMode = .byTruncatingTail

        let row = NSStackView(views: [word])
        row.orientation = .horizontal
        row.spacing = 4
        row.alignment = .centerY

        if suggestion.replacements.isEmpty {
            // No automatic fix: show what harper said instead of an empty row.
            let note = NSTextField(labelWithString: suggestion.message)
            note.font = .systemFont(ofSize: 10)
            note.textColor = .secondaryLabelColor
            note.lineBreakMode = .byTruncatingTail
            row.addArrangedSubview(note)
        } else {
            let arrow = NSTextField(labelWithString: "→")
            arrow.font = .systemFont(ofSize: 10)
            arrow.textColor = .tertiaryLabelColor
            row.addArrangedSubview(arrow)

            for fix in suggestion.replacements.prefix(2) {
                let button = NSButton(title: fix, target: self,
                                      action: #selector(fixTapped(_:)))
                button.bezelStyle = .inline
                button.controlSize = .small
                button.font = .systemFont(ofSize: 11)
                button.tag = index
                button.identifier = NSUserInterfaceItemIdentifier(fix)
                row.addArrangedSubview(button)
            }
        }
        row.addArrangedSubview(NSView())
        row.heightAnchor.constraint(equalToConstant: Metrics.rowHeight).isActive = true
        return row
    }

    // MARK: - Actions

    @objc private func fixTapped(_ sender: NSButton) {
        guard sender.tag < suggestions.count,
              let replacement = sender.identifier?.rawValue,
              let storage = textView.textStorage else { return }
        let suggestion = suggestions[sender.tag]
        guard NSMaxRange(suggestion.range) <= storage.length else { return }

        storage.replaceCharacters(in: suggestion.range, with: replacement)

        // Every later suggestion shifts by the length delta; stale ranges would
        // corrupt the next edit.
        let delta = (replacement as NSString).length - suggestion.range.length
        suggestions = suggestions.enumerated().compactMap { offset, other in
            if offset == sender.tag { return nil }
            guard other.range.location > suggestion.range.location else { return other }
            return Suggestion(id: other.id,
                              range: NSRange(location: other.range.location + delta,
                                             length: other.range.length),
                              message: other.message,
                              replacements: other.replacements)
        }
        decorate()
        renderRows()
        statusLabel.stringValue = suggestions.isEmpty
            ? "all fixed" : "\(suggestions.count) left"
        resize()
    }

    @objc private func rewriteTapped(_ sender: NSButton) {
        guard let onRewrite, sender.tag < RewriteMode.allCases.count else { return }
        let mode = RewriteMode.allCases[sender.tag]
        let input = textView.string
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        setRewriteEnabled(false)
        statusLabel.stringValue = "\(mode.shortTitle.lowercased())…"

        Task { @MainActor in
            defer { self.setRewriteEnabled(true) }
            do {
                let result = try await onRewrite(input, mode)
                guard !result.isEmpty else {
                    self.statusLabel.stringValue = "model returned nothing"
                    return
                }
                self.textBeforeRewrite = input
                self.textView.string = result
                self.undoButton.isHidden = false
                self.suggestions = []
                self.renderRows()
                self.statusLabel.stringValue = "rewritten"
                self.resize()
            } catch {
                self.statusLabel.stringValue = "rewrite failed"
            }
        }
    }

    private func setRewriteEnabled(_ enabled: Bool) {
        rewriteButtons.forEach { $0.isEnabled = enabled }
    }

    @objc private func undoRewrite() {
        guard let previous = textBeforeRewrite else { return }
        textView.string = previous
        textBeforeRewrite = nil
        undoButton.isHidden = true
        statusLabel.stringValue = "reverted"
        resize()
    }

    @objc private func applyTapped() {
        onApply?(textView.string)
        orderOut(nil)
    }

    @objc private func cancelTapped() {
        orderOut(nil)
    }
}

private extension RewriteMode {
    /// Short label so three buttons fit on one line of a narrow card.
    var shortTitle: String {
        switch self {
        case .fixGrammar: return "Fix"
        case .clearer: return "Clearer"
        case .shorter: return "Shorter"
        }
    }
}
