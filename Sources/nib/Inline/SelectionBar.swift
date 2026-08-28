import AppKit

/// A small bar that appears above selected text offering rewrites.
///
/// Selecting a phrase and being offered something is the interaction people
/// expect, and it previously required a hotkey and a full panel. This keeps it
/// in place: select, click, replaced.
final class SelectionBar: NSPanel {
    /// Runs a rewrite and returns the result, or throws.
    var onRewrite: ((RewriteMode) async throws -> String)?
    /// Applies the accepted text over the selection.
    var onAccept: ((String) -> Void)?

    private let buttons = NSStackView()
    private let status = NSTextField(labelWithString: "")
    private let preview = NSTextField(labelWithString: "")
    private let acceptButton = NSButton()
    private var modeButtons: [NSButton] = []
    private var proposal: String?

    private enum Style {
        static let corner: CGFloat = 9
        static let padding: CGFloat = 8
        static let maxWidth: CGFloat = 420
        static let appearDuration: TimeInterval = 0.12
        static let rise: CGFloat = 5
    }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 240, height: 34),
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
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = Style.corner
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.separatorColor.cgColor
        background.layer?.masksToBounds = true
        contentView = background

        buttons.orientation = .horizontal
        buttons.spacing = 4
        for (index, mode) in RewriteMode.allCases.enumerated() {
            let button = NSButton(title: mode.barTitle, target: self,
                                  action: #selector(runMode(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.tag = index
            modeButtons.append(button)
            buttons.addArrangedSubview(button)
        }

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.isHidden = true

        preview.font = .systemFont(ofSize: 12)
        preview.textColor = .labelColor
        preview.lineBreakMode = .byTruncatingTail
        preview.maximumNumberOfLines = 3
        preview.preferredMaxLayoutWidth = Style.maxWidth - Style.padding * 2
        preview.isHidden = true

        acceptButton.title = "Replace"
        acceptButton.bezelStyle = .rounded
        acceptButton.controlSize = .small
        acceptButton.bezelColor = .systemGreen
        acceptButton.target = self
        acceptButton.action = #selector(accept)
        acceptButton.isHidden = true

        let actionRow = NSStackView(views: [buttons, status, NSView(), acceptButton])
        actionRow.orientation = .horizontal
        actionRow.spacing = 6

        let stack = NSStackView(views: [preview, actionRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: Style.padding, left: Style.padding,
                                        bottom: Style.padding, right: Style.padding)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
    }

    // MARK: - Presentation

    /// Shows the bar above `rect`, which is the selection in screen space.
    func present(above rect: CGRect) {
        reset()
        resize()

        var origin = CGPoint(x: rect.midX - frame.width / 2, y: rect.maxY + 8)
        let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 6), visible.maxX - frame.width - 6)
            // No room above the selection: sit below it instead.
            if origin.y + frame.height > visible.maxY - 6 {
                origin.y = rect.minY - frame.height - 8
            }
        }
        setFrameOrigin(origin)

        guard !isVisible else { return }
        alphaValue = 0
        let target = frame
        setFrameOrigin(CGPoint(x: target.origin.x, y: target.origin.y - Style.rise))
        orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Style.appearDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
            animator().setFrame(target, display: true)
        }
    }

    func dismiss() {
        guard isVisible else { return }
        orderOut(nil)
        reset()
    }

    private func reset() {
        proposal = nil
        preview.isHidden = true
        preview.stringValue = ""
        acceptButton.isHidden = true
        status.isHidden = true
        modeButtons.forEach { $0.isEnabled = true }
    }

    private func resize() {
        layoutIfNeeded()
        let fitting = contentView?.fittingSize ?? NSSize(width: 240, height: 34)
        setContentSize(NSSize(width: min(max(200, fitting.width), Style.maxWidth),
                              height: fitting.height))
    }

    // MARK: - Actions

    @objc private func runMode(_ sender: NSButton) {
        guard let onRewrite, sender.tag < RewriteMode.allCases.count else { return }
        let mode = RewriteMode.allCases[sender.tag]

        modeButtons.forEach { $0.isEnabled = false }
        status.stringValue = "thinking…"
        status.isHidden = false
        preview.isHidden = true
        acceptButton.isHidden = true
        resize()

        Task { @MainActor in
            defer { self.modeButtons.forEach { $0.isEnabled = true } }
            do {
                let result = try await onRewrite(mode)
                guard !result.isEmpty else {
                    self.status.stringValue = "no suggestion"
                    return
                }
                // The result is shown before it is applied. A local model can
                // produce something worse than the original, and replacing
                // text without showing it first is not a fair trade.
                self.proposal = result
                self.preview.stringValue = result
                self.preview.isHidden = false
                self.status.isHidden = true
                self.acceptButton.isHidden = false
                self.resize()
            } catch {
                self.status.stringValue = "needs a model"
            }
        }
    }

    @objc private func accept() {
        guard let proposal else { return }
        onAccept?(proposal)
        dismiss()
    }
}

private extension RewriteMode {
    var barTitle: String {
        switch self {
        case .fixGrammar: return "Fix"
        case .clearer: return "Clearer"
        case .shorter: return "Shorter"
        }
    }
}
