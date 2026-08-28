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
    /// Hovering the badge is the substitute for hovering an underline.
    var onHover: ((Bool) -> Void)?

    private let body = BadgeBody()
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
        body.onHover = { [weak self] inside in
            self?.onHover?(inside)
        }
        contentView = body

        let symbol = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        glyph.image = NSImage(systemSymbolName: "pencil.line",
                              accessibilityDescription: "nib")?
            .withSymbolConfiguration(symbol)
        glyph.contentTintColor = Theme.Colour.correction

        label.font = Theme.Font.control
        label.textColor = .labelColor

        let row = NSStackView(views: [glyph, label])
        row.orientation = .horizontal
        row.spacing = 5
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 4, left: 9, bottom: 4, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            row.topAnchor.constraint(equalTo: body.topAnchor),
            row.bottomAnchor.constraint(equalTo: body.bottomAnchor),
        ])
    }

    /// Shows the badge at the trailing edge of the field.
    func show(count: Int, hint: String, near fieldFrame: CGRect) {
        guard count > 0, fieldFrame.width > 0, fieldFrame.height > 0 else {
            dismiss()
            return
        }
        label.stringValue = "\(count) issue\(count == 1 ? "" : "s") · \(hint)"

        body.layoutSubtreeIfNeeded()
        let size = body.fittingSize

        // Just inside the field's trailing edge, clear of the text itself.
        var origin = CGPoint(x: fieldFrame.maxX - size.width - 8,
                             y: fieldFrame.minY + 6)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(fieldFrame) }) {
            let visible = screen.visibleFrame
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
    }
}

/// Hover and click live on the view, not the panel: `updateTrackingAreas` and
/// the mouse responder chain are `NSView` API.
private final class BadgeBody: NSVisualEffectView {
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    private var tracking: NSTrackingArea?
    private var hovering = false { didSet { refresh() } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        NSCursor.pointingHand.set()
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        NSCursor.arrow.set()
        onHover?(false)
    }

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
