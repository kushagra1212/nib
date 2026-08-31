import AppKit

/// The control. Every pressable thing nib draws is one of these.
///
/// AppKit's bezels look like a settings dialog at this size, and a flat fill on
/// a blurred backdrop reads as disabled. What says "pressable" here is a
/// hairline edge, a gradient that catches light from above, and a shadow that
/// grows on hover.
///
/// Its geometry comes from Theme.Metric rather than from itself, so it cannot
/// drift from the segmented control beside it -- which is exactly what happened
/// when this was a capsule and its neighbour was an AppKit segmented control
/// that has no capsule form.
final class PillButton: NSButton {
    enum Emphasis {
        /// Filled with the tint. One per surface, at most.
        case primary
        /// Quiet fill, for the actions beside the primary one.
        case secondary
        /// No fill until hovered, for dismissals.
        case plain
    }

    private var emphasis: Emphasis = .secondary
    private var tint: NSColor = Theme.Colour.accept
    /// Colour of the leading icon, separate from the fill so a quiet button
    /// can still carry a bright glyph.
    private var iconTint: NSColor?
    /// Marked as the current choice, for a button standing in a SegmentedRow.
    ///
    /// Held here rather than in the row so the selected segment is drawn by the
    /// same code as every other state -- one place decides what a control looks
    /// like, which is the whole point of there being one control.
    private var selected = false { didSet { refresh(animated: true) } }
    private var hovering = false { didSet { refresh(animated: true) } }
    private var pressing = false { didSet { refresh(animated: true) } }
    private var tracking: NSTrackingArea?

    private let fillLayer = CAGradientLayer()
    private var iconName: String?

    private enum Metrics {
        static let height = Theme.Metric.control
        static let horizontalPadding = Theme.Metric.controlPadding
        static let iconSpacing = Theme.Metric.glyphGap
        /// How far the button rises under the pointer.
        static let lift: CGFloat = 1
    }

    convenience init(title: String, emphasis: Emphasis = .secondary,
                     tint: NSColor = Theme.Colour.accept,
                     icon: String? = nil, iconTint: NSColor? = nil,
                     target: AnyObject?, action: Selector) {
        self.init(frame: .zero)
        configure(title: title, emphasis: emphasis, tint: tint, icon: icon,
                  iconTint: iconTint, target: target, action: action)
    }

    /// For buttons held as stored properties, which cannot use the convenience
    /// initialiser.
    func configure(title: String, emphasis: Emphasis = .secondary,
                   tint: NSColor = Theme.Colour.accept,
                   icon: String? = nil, iconTint: NSColor? = nil,
                   target: AnyObject?, action: Selector) {
        self.emphasis = emphasis
        self.tint = tint
        self.iconName = icon
        self.iconTint = iconTint
        self.title = title
        self.target = target
        self.action = action
        setUp()
    }

    private func setUp() {
        isBordered = false
        wantsLayer = true
        imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        imageHugsTitle = true

        if let iconName {
            var config = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
            if let iconTint {
                // Palette configuration keeps the glyph's own colour instead of
                // inheriting contentTintColor with the label.
                config = config.applying(.init(paletteColors: [iconTint]))
            }
            image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            image?.isTemplate = iconTint == nil
        }

        if fillLayer.superlayer == nil {
            // Below the title, which AppKit draws into the button's own layer.
            layer?.insertSublayer(fillLayer, at: 0)
        }
        fillLayer.startPoint = CGPoint(x: 0.5, y: 0)
        fillLayer.endPoint = CGPoint(x: 0.5, y: 1)
        fillLayer.borderWidth = Theme.Metric.hairline
        fillLayer.cornerCurve = .continuous

        layer?.shadowOffset = CGSize(width: 0, height: -1)
        layer?.shadowRadius = 2.5
        refresh(animated: false)
    }

    override var intrinsicContentSize: NSSize {
        var width = Metrics.horizontalPadding * 2
        if !title.isEmpty {
            width += attributedTitle.size().width
        }
        if image != nil {
            width += 12 + (title.isEmpty ? 0 : Metrics.iconSpacing)
        }
        return NSSize(width: ceil(width), height: Metrics.height)
    }

    override func layout() {
        super.layout()
        // A true capsule: the radius tracks the height rather than a constant,
        // so the shape stays right if the metrics change.
        let radius = Theme.Radius.control
        fillLayer.frame = bounds
        fillLayer.cornerRadius = radius
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius,
                                   cornerHeight: radius, transform: nil)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh(animated: false)
    }

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
        guard isEnabled else { return }
        hovering = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        pressing = false
    }

    override func mouseDown(with event: NSEvent) {
        pressing = true
        super.mouseDown(with: event)
        pressing = false
    }

    override var isEnabled: Bool {
        didSet {
            if !isEnabled { hovering = false }
            refresh(animated: true)
        }
    }

    // MARK: - Appearance

    /// Top and bottom of the gradient, so the capsule reads as lit from above.
    private var gradient: (NSColor, NSColor) {
        guard isEnabled else {
            let flat = NSColor.controlColor.withAlphaComponent(0.18)
            return (flat, flat)
        }
        // Gilding is a line, not a slab: the chosen segment is washed with the
        // accent and edged in it, rather than flooded. Solid brass behind small
        // serif type is unreadable, and it also shouts across a row that is
        // meant to read as one object.
        if selected {
            let wash = pressing ? 0.30 : (hovering ? 0.26 : 0.20)
            return (tint.withAlphaComponent(wash),
                    tint.withAlphaComponent(wash * 0.7))
        }
        switch emphasis {
        case .primary:
            let base = pressing ? tint.shaded(0.16) : tint
            return (base.tinted(hovering ? 0.16 : 0.08), base.shaded(0.06))
        case .secondary:
            let top: CGFloat = pressing ? 0.07 : (hovering ? 0.20 : 0.13)
            let bottom: CGFloat = pressing ? 0.05 : (hovering ? 0.14 : 0.08)
            return (Theme.Colour.controlFill(top), Theme.Colour.controlFill(bottom))
        case .plain:
            guard hovering || pressing else { return (.clear, .clear) }
            let alpha: CGFloat = pressing ? 0.07 : 0.13
            return (Theme.Colour.controlFill(alpha),
                    Theme.Colour.controlFill(alpha * 0.7))
        }
    }

    /// Marks this as the chosen one of a set.
    func setSelected(_ isSelected: Bool, tint: NSColor) {
        self.tint = tint
        selected = isSelected
    }

    private var borderColour: NSColor {
        guard isEnabled else { return .clear }
        if selected { return tint.withAlphaComponent(0.55) }
        switch emphasis {
        case .primary:
            return tint.shaded(0.22).withAlphaComponent(0.9)
        case .secondary:
            return Theme.Colour.controlEdge(hovering ? 0.26 : 0.15)
        case .plain:
            return hovering ? Theme.Colour.controlEdge(0.15) : .clear
        }
    }

    private var textColour: NSColor {
        guard isEnabled else { return Theme.Colour.inkMuted }
        if selected { return Theme.Colour.ink }
        return emphasis == .primary ? Theme.Colour.ivory : Theme.Colour.ink
    }

    /// Tinting the whole button would recolour the label too, so the icon
    /// carries its colour through the symbol configuration instead.
    private var labelTint: NSColor? {
        iconTint == nil ? textColour : nil
    }

    private func refresh(animated: Bool) {
        let (top, bottom) = gradient
        let apply = {
            self.fillLayer.colors = [top.cgColor, bottom.cgColor]
            self.fillLayer.borderColor = self.borderColour.cgColor
            // Shadow only while hovered, so a resting row stays flat and
            // quiet rather than looking like a set of floating chips.
            self.layer?.shadowOpacity = self.hovering && !self.pressing ? 0.22 : 0
            self.layer?.transform = CATransform3DMakeTranslation(
                0, self.hovering && !self.pressing ? Metrics.lift : 0, 0)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(Theme.Motion.hover)
        // A dynamic NSColor resolves when it is converted to cgColor, using
        // whatever appearance is current at that moment. Without this the
        // colours freeze at whatever was active the first time.
        effectiveAppearance.performAsCurrentDrawingAppearance(apply)
        CATransaction.commit()

        contentTintColor = labelTint
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: Theme.Font.control,
            .foregroundColor: textColour,
        ])
    }
}

private extension NSColor {
    /// Mixes towards white.
    func tinted(_ amount: CGFloat) -> NSColor {
        blended(withFraction: amount, of: .white) ?? self
    }

    /// Mixes towards black.
    func shaded(_ amount: CGFloat) -> NSColor {
        blended(withFraction: amount, of: .black) ?? self
    }
}

/// A small rounded label used for counts and status.
final class Pill: NSView {
    private let label = NSTextField(labelWithString: "")

    var text: String = "" {
        didSet {
            label.stringValue = text
            isHidden = text.isEmpty
            invalidateIntrinsicContentSize()
        }
    }

    var tint: NSColor = Theme.Colour.inkMuted {
        didSet {
            layer?.backgroundColor = tint.withAlphaComponent(0.14).cgColor
            layer?.borderColor = tint.withAlphaComponent(0.22).cgColor
            label.textColor = tint
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Theme.Metric.hairline
        layer?.backgroundColor = Theme.Colour.inkMuted
            .withAlphaComponent(0.14).cgColor

        label.font = Theme.Font.title
        label.textColor = Theme.Colour.inkMuted
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = Theme.Radius.control
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: label.intrinsicContentSize.width + 16, height: 18)
    }
}
