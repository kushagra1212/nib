import AppKit

/// A capsule control that lifts under the pointer and dips when pressed.
///
/// AppKit's bezels look like a settings dialog at this size, and a flat fill on
/// a blurred backdrop reads as disabled. Every part here exists to say
/// "pressable": a capsule silhouette, a gradient so it catches light from
/// above, a hairline edge so it separates from the blur behind it, and a shadow
/// that grows on hover.
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
    private var hovering = false { didSet { refresh(animated: true) } }
    private var pressing = false { didSet { refresh(animated: true) } }
    private var tracking: NSTrackingArea?

    private let fillLayer = CAGradientLayer()
    private var iconName: String?

    private enum Metrics {
        static let height: CGFloat = 26
        static let horizontalPadding: CGFloat = 13
        static let iconSpacing: CGFloat = 5
        /// How far the button rises under the pointer.
        static let lift: CGFloat = 1
    }

    convenience init(title: String, emphasis: Emphasis = .secondary,
                     tint: NSColor = Theme.Colour.accept,
                     icon: String? = nil,
                     target: AnyObject?, action: Selector) {
        self.init(frame: .zero)
        configure(title: title, emphasis: emphasis, tint: tint, icon: icon,
                  target: target, action: action)
    }

    /// For buttons held as stored properties, which cannot use the convenience
    /// initialiser.
    func configure(title: String, emphasis: Emphasis = .secondary,
                   tint: NSColor = Theme.Colour.accept,
                   icon: String? = nil,
                   target: AnyObject?, action: Selector) {
        self.emphasis = emphasis
        self.tint = tint
        self.iconName = icon
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
            let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
        }

        if fillLayer.superlayer == nil {
            // Below the title, which AppKit draws into the button's own layer.
            layer?.insertSublayer(fillLayer, at: 0)
        }
        fillLayer.startPoint = CGPoint(x: 0.5, y: 0)
        fillLayer.endPoint = CGPoint(x: 0.5, y: 1)
        fillLayer.borderWidth = 1
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
        let radius = bounds.height / 2
        fillLayer.frame = bounds
        fillLayer.cornerRadius = radius
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius,
                                   cornerHeight: radius, transform: nil)
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
        switch emphasis {
        case .primary:
            let base = pressing ? tint.shaded(0.16) : tint
            return (base.tinted(hovering ? 0.16 : 0.08), base.shaded(0.06))
        case .secondary:
            let top: CGFloat = pressing ? 0.30 : (hovering ? 0.72 : 0.52)
            let bottom: CGFloat = pressing ? 0.24 : (hovering ? 0.58 : 0.40)
            return (NSColor.controlColor.withAlphaComponent(top),
                    NSColor.controlColor.withAlphaComponent(bottom))
        case .plain:
            guard hovering || pressing else { return (.clear, .clear) }
            let alpha: CGFloat = pressing ? 0.28 : 0.45
            return (NSColor.controlColor.withAlphaComponent(alpha),
                    NSColor.controlColor.withAlphaComponent(alpha * 0.8))
        }
    }

    private var borderColour: NSColor {
        guard isEnabled else { return .clear }
        switch emphasis {
        case .primary:
            return tint.shaded(0.22).withAlphaComponent(0.9)
        case .secondary:
            return NSColor.separatorColor.withAlphaComponent(hovering ? 0.9 : 0.55)
        case .plain:
            return hovering ? NSColor.separatorColor.withAlphaComponent(0.6) : .clear
        }
    }

    private var textColour: NSColor {
        guard isEnabled else { return .tertiaryLabelColor }
        return emphasis == .primary ? .white : .labelColor
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
        apply()
        CATransaction.commit()

        contentTintColor = textColour
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

    var tint: NSColor = .secondaryLabelColor {
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
        layer?.borderWidth = 1
        layer?.backgroundColor = NSColor.secondaryLabelColor
            .withAlphaComponent(0.14).cgColor

        label.font = Theme.Font.title
        label.textColor = .secondaryLabelColor
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
        layer?.cornerRadius = bounds.height / 2
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: label.intrinsicContentSize.width + 16, height: 18)
    }
}
