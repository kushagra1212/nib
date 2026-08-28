import AppKit

/// The hotkey surface, for fields where marks cannot be placed.
///
/// Laid out as a card with a header, the text, the fixes, then the actions.
/// The previous version was a form: stock bezels, no hierarchy, and a large
/// gap under the text because the editor claimed whatever height was going.
final class SuggestionPanel: NSPanel {
    private enum Metrics {
        static let width: CGFloat = 400
        static let maxTextHeight: CGFloat = 128
        static let minTextHeight: CGFloat = 24
        static let rowHeight: CGFloat = 24
        static let maxVisibleRows = 4
    }

    private let textView = NSTextView()
    private let textScroll = NSScrollView()
    private let titleLabel = NSTextField(labelWithString: "nib")
    private let statusPill = Pill()
    private let rowsStack = NSStackView()
    private let overflowLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private var rewriteButtons: [PillButton] = []
    private var undoButton: PillButton!
    private var textHeight: NSLayoutConstraint!

    private var suggestions: [Suggestion] = []
    private var onApply: ((String) -> Void)?
    private var onRequestFixes: (([Suggestion]) async -> [Suggestion])?
    private var onRewrite: ((String, RewriteMode) async throws -> String)?
    private var textBeforeRewrite: String?

    var currentText: String { textView.string }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Metrics.width, height: 120),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        build()
    }

    override var canBecomeKey: Bool { true }

    private func build() {
        let background = Theme.makeBackground()
        contentView = background

        // Header: what this is, and how it is going.
        titleLabel.font = Theme.Font.title
        titleLabel.textColor = .secondaryLabelColor

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let header = NSStackView(views: [titleLabel, spinner, NSView(), statusPill])
        header.orientation = .horizontal
        header.spacing = Theme.Space.tight
        header.alignment = .centerY

        // Editor. Built in code, so it needs explicit sizing or it lays out
        // nothing at all.
        let contentWidth = Metrics.width - Theme.Space.edge * 2
        let unbounded = CGFloat.greatestFiniteMagnitude
        textView.frame = NSRect(x: 0, y: 0, width: contentWidth,
                                height: Metrics.minTextHeight)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: unbounded, height: unbounded)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: contentWidth,
                                                       height: unbounded)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = .zero
        textView.isRichText = false
        textView.font = Theme.Font.body
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.drawsBackground = false

        textScroll.documentView = textView
        textScroll.drawsBackground = false
        textScroll.borderType = .noBorder
        textScroll.hasVerticalScroller = false
        textScroll.translatesAutoresizingMaskIntoConstraints = false
        textHeight = textScroll.heightAnchor.constraint(
            equalToConstant: Metrics.minTextHeight)
        textHeight.isActive = true

        let divider = NSBox()
        divider.boxType = .separator

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 2

        overflowLabel.font = Theme.Font.caption
        overflowLabel.textColor = .tertiaryLabelColor
        overflowLabel.isHidden = true

        // Actions.
        let rewriteRow = NSStackView()
        rewriteRow.orientation = .horizontal
        rewriteRow.spacing = Theme.Space.tight
        for (index, mode) in RewriteMode.allCases.enumerated() {
            let button = PillButton(title: mode.shortTitle, emphasis: .secondary,
                                    icon: mode.icon, iconTint: mode.iconTint,
                                    target: self,
                                    action: #selector(rewriteTapped(_:)))
            button.tag = index
            rewriteButtons.append(button)
            rewriteRow.addArrangedSubview(button)
        }
        undoButton = PillButton(title: "Undo", emphasis: .plain,
                                target: self, action: #selector(undoRewrite))
        undoButton.keyEquivalent = "z"
        undoButton.keyEquivalentModifierMask = .command
        undoButton.isHidden = true
        rewriteRow.addArrangedSubview(undoButton)

        let cancel = PillButton(title: "Esc", emphasis: .plain,
                                target: self, action: #selector(cancelTapped))
        cancel.keyEquivalent = "\u{1b}"
        let replace = PillButton(title: "Replace", emphasis: .primary,
                                 tint: Theme.Colour.clarity,
                                 target: self, action: #selector(applyTapped))
        replace.keyEquivalent = "\r"

        let actions = NSStackView(views: [rewriteRow, NSView(), cancel, replace])
        actions.orientation = .horizontal
        actions.spacing = Theme.Space.tight

        let root = NSStackView(views: [
            header, textScroll, divider, rowsStack, overflowLabel, actions,
        ])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = Theme.Space.row
        root.edgeInsets = NSEdgeInsets(top: Theme.Space.edge, left: Theme.Space.edge,
                                       bottom: Theme.Space.edge, right: Theme.Space.edge)
        root.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            root.topAnchor.constraint(equalTo: background.topAnchor),
            root.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            textScroll.widthAnchor.constraint(equalToConstant: contentWidth),
            divider.widthAnchor.constraint(equalToConstant: contentWidth),
            header.widthAnchor.constraint(equalToConstant: contentWidth),
            actions.widthAnchor.constraint(equalToConstant: contentWidth),
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
        textBeforeRewrite = nil
        undoButton.isHidden = true

        textView.string = text
        suggestions = []
        renderRows()
        setStatus("checking", tint: .secondaryLabelColor)
        spinner.startAnimation(nil)

        resize(animated: false)
        Theme.present(self, at: framePositioned(near: point))
        makeKey()
    }

    private func framePositioned(near point: NSPoint?) -> NSRect {
        guard let point, let screen = NSScreen.main else {
            var centred = frame
            if let visible = NSScreen.main?.visibleFrame {
                centred.origin = CGPoint(x: visible.midX - frame.width / 2,
                                         y: visible.midY - frame.height / 2)
            }
            return centred
        }
        var origin = NSPoint(x: point.x - 20, y: point.y - frame.height - 20)
        let visible = screen.visibleFrame
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - frame.width - 8)
        if origin.y < visible.minY + 8 { origin.y = point.y + 20 }
        origin.y = min(origin.y, visible.maxY - frame.height - 8)
        return NSRect(origin: origin, size: frame.size)
    }

    func show(_ found: [Suggestion]) {
        spinner.stopAnimation(nil)
        suggestions = found
        decorate()
        if found.isEmpty {
            setStatus("looks clean", tint: Theme.Colour.accept)
        } else {
            setStatus("\(found.count) issue\(found.count == 1 ? "" : "s")",
                      tint: Theme.Colour.correction)
        }
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
        spinner.stopAnimation(nil)
        setStatus(message, tint: .systemOrange)
    }

    private func setStatus(_ text: String, tint: NSColor) {
        statusPill.tint = tint
        statusPill.text = text
    }

    private func resize(animated: Bool = true) {
        contentView?.layoutSubtreeIfNeeded()

        var measured = Metrics.minTextHeight
        if let manager = textView.layoutManager, let container = textView.textContainer {
            manager.ensureLayout(for: container)
            measured = manager.usedRect(for: container).height
        }
        // Clamped tightly. Letting the editor take the slack is what left a
        // block of empty space under a single line of text.
        textHeight.constant = min(max(measured, Metrics.minTextHeight),
                                  Metrics.maxTextHeight)
        textScroll.hasVerticalScroller = measured > Metrics.maxTextHeight

        contentView?.layoutSubtreeIfNeeded()
        let fitting = contentView?.fittingSize ?? NSSize(width: Metrics.width, height: 120)
        Theme.resize(self, to: NSSize(width: Metrics.width, height: ceil(fitting.height)),
                     animated: animated)
    }

    private func decorate() {
        guard let storage = textView.textStorage else { return }
        let whole = NSRange(location: 0, length: storage.length)
        storage.removeAttribute(.underlineStyle, range: whole)
        storage.removeAttribute(.underlineColor, range: whole)
        storage.removeAttribute(.backgroundColor, range: whole)

        for suggestion in suggestions {
            guard NSMaxRange(suggestion.range) <= storage.length else { continue }
            let tint = suggestion.kind == .correction
                ? Theme.Colour.correction : Theme.Colour.clarity
            storage.addAttributes([
                .underlineStyle: NSUnderlineStyle.thick.rawValue,
                .underlineColor: tint,
                .backgroundColor: tint.withAlphaComponent(0.10),
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

    private func makeRow(_ suggestion: Suggestion, index: Int) -> NSView {
        let excerpt = suggestion.excerpt(in: textView.string) ?? ""
        let word = NSTextField(labelWithString: excerpt)
        word.font = Theme.Font.control
        word.textColor = suggestion.kind == .correction
            ? Theme.Colour.correction : Theme.Colour.clarity
        word.lineBreakMode = .byTruncatingTail

        let row = NSStackView(views: [word])
        row.orientation = .horizontal
        row.spacing = Theme.Space.tight
        row.alignment = .centerY

        if suggestion.replacements.isEmpty {
            let note = NSTextField(labelWithString: suggestion.message)
            note.font = Theme.Font.caption
            note.textColor = .secondaryLabelColor
            note.lineBreakMode = .byTruncatingTail
            row.addArrangedSubview(note)
        } else {
            let arrow = NSTextField(labelWithString: "→")
            arrow.font = Theme.Font.caption
            arrow.textColor = .tertiaryLabelColor
            row.addArrangedSubview(arrow)

            for fix in suggestion.replacements.prefix(2) {
                let button = PillButton(title: fix, emphasis: .secondary,
                                        target: self, action: #selector(fixTapped(_:)))
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
        let edit = TextEdit(range: suggestion.range, replacement: replacement,
                            expected: suggestion.excerpt(in: textView.string) ?? "")
        guard let updated = EditPlanner.apply(edit, to: textView.string) else { return }

        storage.replaceCharacters(in: suggestion.range, with: replacement)
        suggestions = EditPlanner.pruneOutOfBounds(
            EditPlanner.reanchor(suggestions, after: edit), in: updated)
        decorate()
        renderRows()
        setStatus(suggestions.isEmpty ? "all fixed" : "\(suggestions.count) left",
                  tint: suggestions.isEmpty ? Theme.Colour.accept : Theme.Colour.correction)
        resize()
    }

    @objc private func rewriteTapped(_ sender: NSButton) {
        guard let onRewrite, sender.tag < RewriteMode.allCases.count else { return }
        let mode = RewriteMode.allCases[sender.tag]
        let input = textView.string
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        rewriteButtons.forEach { $0.isEnabled = false }
        spinner.startAnimation(nil)
        setStatus(mode.shortTitle.lowercased() + "…", tint: .secondaryLabelColor)

        Task { @MainActor in
            defer {
                self.rewriteButtons.forEach { $0.isEnabled = true }
                self.spinner.stopAnimation(nil)
            }
            do {
                let result = try await onRewrite(input, mode)
                guard !result.isEmpty else {
                    self.setStatus("no suggestion", tint: .systemOrange)
                    return
                }
                self.textBeforeRewrite = input
                self.textView.string = result
                self.undoButton.isHidden = false
                self.suggestions = []
                self.renderRows()
                self.setStatus("rewritten", tint: Theme.Colour.accept)
                self.resize()
            } catch {
                self.setStatus("needs a model", tint: .systemOrange)
            }
        }
    }

    @objc private func undoRewrite() {
        guard let previous = textBeforeRewrite else { return }
        textView.string = previous
        textBeforeRewrite = nil
        undoButton.isHidden = true
        setStatus("reverted", tint: .secondaryLabelColor)
        resize()
    }

    @objc private func applyTapped() {
        onApply?(textView.string)
        Theme.dismiss(self)
    }

    @objc private func cancelTapped() {
        Theme.dismiss(self)
    }
}

extension RewriteMode {
    /// Short label so three buttons fit on one line of a narrow card.
    var shortTitle: String {
        switch self {
        case .fixGrammar: return "Fix"
        case .clearer: return "Clearer"
        case .shorter: return "Shorter"
        }
    }

    /// Icon carrying the action, so the row reads before the labels do.
    var icon: String {
        switch self {
        case .fixGrammar: return "checkmark"
        case .clearer: return "wand.and.rays"
        case .shorter: return "arrow.down.right.and.arrow.up.left"
        }
    }

    /// Colour of that icon. Three grey chips are hard to tell apart at a
    /// glance; three colours are not.
    var iconTint: NSColor {
        switch self {
        case .fixGrammar: return Theme.Colour.fix
        case .clearer: return Theme.Colour.rewrite
        case .shorter: return Theme.Colour.condense
        }
    }
}
