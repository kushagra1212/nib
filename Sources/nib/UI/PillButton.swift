import AppKit

/// A compact control that lights up under the pointer and dips when pressed.
///
/// NSButton's stock bezels look like a settings dialog at this size, which is
/// what made the panel read as a form rather than a suggestion. Drawn here so
/// the hover and press feedback exist at all: a floating surface with inert
/// controls feels broken even when it works.
final class PillButton: NSButton {
    enum Emphasis {
        /// Fills with the tint. One per surface, at most.
        case primary
        /// Quiet fill, for the actions beside the primary one.
        case secondary
        /// No fill until hovered, for dismissals.
        case plain
    }

    private var emphasis: Emphasis = .secondary
    private var tint: NSColor = Theme.Colour.accept
    private var hovering = false { didSet { refresh(animated: true) } }
    private var tracking: NSTrackingArea?

    convenience init(title: String, emphasis: Emphasis = .secondary,
                     tint: NSColor = Theme.Colour.accept,
                     target: AnyObject?, action: Selector) {
        self.init(frame: .zero)
        self.emphasis = emphasis
        self.tint = tint
        self.title = title
        self.target = target
        self.action = action
        setUp()
    }

    private func setUp() {
        isBordered = false
        wantsLayer = true
        font = Theme.Font.control
        layer?.cornerRadius = Theme.Radius.control
        layer?.cornerCurve = .continuous
        refresh(animated: false)
    }

    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        return NSSize(width: base.width + 20, height: 24)
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

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        // A brief inset instead of a scale: scaling a layer with text in it
        // resamples the glyphs and looks blurry mid-animation.
        animateBackground(to: pressedFill, duration: 0.04)
        super.mouseDown(with: event)
        refresh(animated: true)
    }

    override var isEnabled: Bool {
        didSet { refresh(animated: false) }
    }

    // MARK: - Appearance

    private var fill: NSColor {
        guard isEnabled else { return NSColor.controlColor.withAlphaComponent(0.25) }
        switch emphasis {
        case .primary:
            return hovering ? tint.blended(withFraction: 0.12, of: .white) ?? tint : tint
        case .secondary:
            return hovering ? Theme.Colour.controlHover : Theme.Colour.controlFill
        case .plain:
            return hovering ? Theme.Colour.controlFill : .clear
        }
    }

    private var pressedFill: NSColor {
        emphasis == .primary
            ? (tint.blended(withFraction: 0.18, of: .black) ?? tint)
            : NSColor.controlColor
    }

    private var textColour: NSColor {
        guard isEnabled else { return .tertiaryLabelColor }
        return emphasis == .primary ? .white : .labelColor
    }

    private func refresh(animated: Bool) {
        animateBackground(to: fill, duration: animated ? Theme.Motion.hover : 0)
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: Theme.Font.control,
            .foregroundColor: textColour,
        ])
    }

    private func animateBackground(to colour: NSColor, duration: TimeInterval) {
        guard let layer else { return }
        guard duration > 0 else {
            layer.backgroundColor = colour.cgColor
            return
        }
        let fade = CABasicAnimation(keyPath: "backgroundColor")
        fade.fromValue = layer.backgroundColor
        fade.toValue = colour.cgColor
        fade.duration = duration
        fade.timingFunction = Theme.Motion.easeOut
        layer.add(fade, forKey: "fill")
        layer.backgroundColor = colour.cgColor
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
            label.textColor = tint
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.pill
        layer?.cornerCurve = .continuous
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

    override var intrinsicContentSize: NSSize {
        NSSize(width: label.intrinsicContentSize.width + 16, height: 18)
    }
}
