import AppKit

/// The floating editor that appears on the hotkey.
///
/// A nonactivating panel, so the app the text came from keeps its focus ring
/// and its notion of where the insertion point is. That matters: writing the
/// result back depends on the original app still holding its selection.
final class SuggestionPanel: NSPanel {
    private let textView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let listStack = NSStackView()
    private let applyButton = NSButton()

    private var suggestions: [Suggestion] = []
    private var onApply: ((String) -> Void)?
    private var onRequestFixes: (([Suggestion]) async -> [Suggestion])?

    var currentText: String { textView.string }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        buildLayout()
    }

    // Panels that are not key by default still need to accept typing.
    override var canBecomeKey: Bool { true }

    private func buildLayout() {
        let content = NSView()
        contentView = content

        textView.isRichText = false
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 4
        listStack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

        let listScroll = NSScrollView()
        listScroll.documentView = listStack
        listScroll.hasVerticalScroller = true
        listScroll.borderType = .noBorder
        listScroll.drawsBackground = false

        applyButton.title = "Replace"
        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"
        applyButton.target = self
        applyButton.action = #selector(applyTapped)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}" // Esc

        let buttons = NSStackView(views: [statusLabel, NSView(), cancel, applyButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let split = NSSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(scroll)
        split.addArrangedSubview(listScroll)

        let root = NSStackView(views: [split, buttons])
        root.orientation = .vertical
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 28, left: 12, bottom: 12, right: 12)
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])
    }

    // MARK: - Presentation

    func present(
        text: String,
        near point: NSPoint?,
        onApply: @escaping (String) -> Void,
        requestFixes: @escaping ([Suggestion]) async -> [Suggestion]
    ) {
        self.onApply = onApply
        self.onRequestFixes = requestFixes
        textView.string = text
        suggestions = []
        renderList()
        statusLabel.stringValue = "checking…"

        if let point {
            setFrameTopLeftPoint(point)
        } else {
            center()
        }
        orderFrontRegardless()
        makeKey()
    }

    /// Shows lint results: underlines in the text, one row per suggestion.
    func show(_ found: [Suggestion]) {
        suggestions = found
        decorate()
        statusLabel.stringValue = found.isEmpty
            ? "no issues"
            : "\(found.count) issue\(found.count == 1 ? "" : "s")"
        renderList()

        // Replacement text is fetched lazily, so pull it for what is on screen.
        guard let onRequestFixes else { return }
        let visible = Array(found.prefix(30))
        Task { @MainActor in
            let filled = await onRequestFixes(visible)
            guard self.suggestions.count >= filled.count else { return }
            self.suggestions.replaceSubrange(0..<filled.count, with: filled)
            self.renderList()
        }
    }

    func showError(_ message: String) {
        statusLabel.stringValue = message
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

    private func renderList() {
        listStack.arrangedSubviews.forEach {
            listStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        for (index, suggestion) in suggestions.enumerated() {
            let excerpt = suggestion.excerpt(in: textView.string) ?? ""
            let label = NSTextField(labelWithString: "\(excerpt) — \(suggestion.message)")
            label.font = .systemFont(ofSize: 11)
            label.lineBreakMode = .byTruncatingTail

            let row = NSStackView(views: [label])
            row.orientation = .horizontal
            row.spacing = 6

            // One button per replacement, capped: harper offers up to a dozen
            // spellings and a row of twelve buttons is not a decision aid.
            for fix in suggestion.replacements.prefix(3) {
                let button = NSButton(title: fix, target: self, action: #selector(fixTapped(_:)))
                button.bezelStyle = .inline
                button.font = .systemFont(ofSize: 11)
                button.tag = index
                button.identifier = NSUserInterfaceItemIdentifier(fix)
                row.addArrangedSubview(button)
            }
            listStack.addArrangedSubview(row)
        }
    }

    // MARK: - Actions

    @objc private func fixTapped(_ sender: NSButton) {
        guard sender.tag < suggestions.count,
              let replacement = sender.identifier?.rawValue,
              let storage = textView.textStorage else { return }
        let suggestion = suggestions[sender.tag]
        guard NSMaxRange(suggestion.range) <= storage.length else { return }

        storage.replaceCharacters(in: suggestion.range, with: replacement)

        // Every later suggestion shifts by the length delta, so recompute rather
        // than leaving stale ranges that would corrupt the next edit.
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
        renderList()
        statusLabel.stringValue = suggestions.isEmpty
            ? "all fixed" : "\(suggestions.count) left"
    }

    @objc private func applyTapped() {
        onApply?(textView.string)
        orderOut(nil)
    }

    @objc private func cancelTapped() {
        orderOut(nil)
    }
}
