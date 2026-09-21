import AppKit

/// A small count that appears beside a field whose text cannot be underlined.
///
/// Some apps report their text but not where it sits on screen. Slack is one:
/// it answers the bounds attribute with an empty rectangle, so there is nowhere
/// to draw. Showing nothing in that case is indistinguishable from having found
/// nothing, which is why nib appeared broken there. The badge says what was
/// found and points at the way to see it.
final class IssueBadge: NSPanel {
    var onOpen: (() -> Void)?

    fileprivate let body = BadgeBody()
    private let label = NSTextField(labelWithString: "")
    private let glyph = NSImageView()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 120, height: 22),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        build()
    }

    override var canBecomeKey: Bool { false }

    private func build() {
        body.material = .hudWindow
        body.blendingMode = .behindWindow
        body.state = .active
        body.isEmphasized = false
        body.wantsLayer = true
        body.layer?.cornerRadius = 11
        body.layer?.cornerCurve = .continuous
        body.layer?.masksToBounds = true
        body.onClick = { [weak self] in
            self?.onOpen?()
            self?.dismiss()
        }
        contentView = body

        let symbol = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        glyph.image = NSImage(systemSymbolName: "pencil.line",
                              accessibilityDescription: "nib")?
            .withSymbolConfiguration(symbol)
        glyph.contentTintColor = Theme.Colour.correction

        label.font = Theme.Font.control
        label.textColor = Theme.Colour.ink

        let row = NSStackView(views: [glyph, label])
        row.orientation = .horizontal
        row.spacing = 5
        row.alignment = .centerY
        // Roomy enough vertically to be an easy hover target: the first
        // version came out 15 points tall, which is a hard thing to land on.
        row.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 11)
        row.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            row.topAnchor.constraint(equalTo: body.topAnchor),
            row.bottomAnchor.constraint(equalTo: body.bottomAnchor),
        ])
    }

    /// Shows the badge just above the field it is counting for.
    func show(count: Int, hint: String, near fieldFrame: CGRect) {
        guard count > 0, fieldFrame.width > 0, fieldFrame.height > 0 else {
            dismiss()
            return
        }
        label.stringValue = "\(count) issue\(count == 1 ? "" : "s") · \(hint)"

        body.layoutSubtreeIfNeeded()
        let size = body.fittingSize

        // Just above the field, aligned with where its text begins.
        //
        // The trailing edge is the obvious spot and the wrong one: that is
        // where apps keep their send and attach buttons, so the badge landed
        // on top of Slack's and read as part of Slack rather than as a note
        // about the text. Above the leading edge sits next to the words it is
        // counting and covers nothing the field owns.
        var origin = CGPoint(x: fieldFrame.minX + 4,
                             y: fieldFrame.maxY + 4)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(fieldFrame) }) {
            let visible = screen.visibleFrame
            // No room above -- a field at the top of the window -- so sit
            // under it rather than be clamped back on top of the text.
            if origin.y + size.height > visible.maxY - 4 {
                origin.y = fieldFrame.minY - size.height - 4
            }
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
            origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)
        }

        let target = NSRect(origin: origin, size: size)
        if isVisible {
            setFrame(target, display: true)
        } else {
            Theme.present(self, at: target)
        }
    }

    func dismiss() {
        Theme.dismiss(self)
        body.hovering = false
    }

    /// Set by the pointer poll, since the badge receives no hover events.
    func setHovered(_ hovered: Bool) {
        guard body.hovering != hovered else { return }
        body.hovering = hovered
    }
}

/// Clicks arrive normally. Hover does not: macOS delivers no mouse-moved
/// events to a non-activating panel owned by a background accessory app, so
/// `LiveChecker` polls the pointer and sets `hovering` itself.
private final class BadgeBody: NSVisualEffectView {
    var onClick: (() -> Void)?

    var hovering = false { didSet { refresh() } }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    private func refresh() {
        layer?.borderColor = hovering
            ? Theme.Colour.correction.withAlphaComponent(0.65).cgColor
            : NSColor.clear.cgColor
        layer?.borderWidth = hovering ? 1 : 0
    }
}
