import AppKit

/// A dark surface with three coloured lights bleeding through it.
///
/// The northern-lights effect, which needs two things to work and fails
/// obviously without either.
///
/// **A dark base.** Aurora is light seen against darkness; over a pale
/// background there is nothing for it to glow against and the colours read as
/// smudges. nib's panels float over other applications, whose backgrounds
/// could be anything, so the base is drawn here rather than borrowed from
/// behind. That is also why this looks the same in light mode as in dark.
///
/// **Three hues at most.** Overlapping translucent gradients converge towards
/// grey-brown, and a fourth light is what turns an aurora into mud. Teal,
/// violet and blue: adjacent on the wheel, so their overlaps stay in the same
/// family instead of cancelling.
///
/// Radial gradient layers rather than blurred shapes. A Gaussian blur over a
/// panel this size costs a filter pass on every resize, and a radial gradient
/// with a soft falloff is the same picture for the price of a fill.
final class AuroraBackground: NSView {
    /// Where a light sits, as a fraction of the view, and how large it is
    /// relative to the view's width.
    ///
    /// Not private: `Contrast` reads the same values to work out how bright
    /// this backdrop can get under a caption, and two copies of these numbers
    /// would let the check pass while the panel it describes went dark.
    struct Light {
        let colour: NSColor
        let centre: CGPoint
        let radius: CGFloat
    }

    private let base = CALayer()
    private var lights: [CAGradientLayer] = []

    /// Near-black with a blue cast rather than neutral: a warm or neutral base
    /// makes the teal look like a stain on grey.
    static let baseColour = NSColor(srgbRed: 0.055, green: 0.06, blue: 0.08,
                                    alpha: 1)

    /// Where the gradient's alpha stops sit, as a fraction of the radius.
    static let stops: [CGFloat] = [0, 0.45, 1]

    /// Off-centre and different sizes. Three lights at even spacing reads as a
    /// pattern; the effect depends on looking unplanned.
    static let plan: [Light] = [
        Light(colour: NSColor(srgbRed: 0.22, green: 0.78, blue: 0.72, alpha: 1),
              centre: CGPoint(x: 0.12, y: 0.85), radius: 0.55),
        Light(colour: NSColor(srgbRed: 0.55, green: 0.36, blue: 0.92, alpha: 1),
              centre: CGPoint(x: 0.62, y: 0.15), radius: 0.70),
        Light(colour: NSColor(srgbRed: 0.20, green: 0.52, blue: 0.95, alpha: 1),
              centre: CGPoint(x: 0.95, y: 0.75), radius: 0.60),
    ]

    /// How strongly the lights show. Low, because this sits behind text that
    /// has to stay the most legible thing on the panel -- the aurora is a
    /// backdrop, not a subject.
    ///
    /// 0.28, down from 0.38, and the number was measured rather than chosen.
    /// Where the violet and the blue overlap, the backdrop climbed to a mid
    /// blue bright enough that the muted text on top of it fell to 3.4:1 and
    /// the selection tint to 2.9:1 -- under the 4.5:1 that small text needs and
    /// under the 3:1 that a control edge needs. At 0.28 the same worst point
    /// leaves 6.5:1 and 4.9:1. `ContrastTests` holds it there.
    static let intensity: CGFloat = 0.28

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { nil }

    private func build() {
        wantsLayer = true
        setAccessibilityElement(false)
        guard let host = layer else { return }

        base.backgroundColor = Self.baseColour.cgColor
        host.addSublayer(base)

        for light in Self.plan {
            let gradient = CAGradientLayer()
            gradient.type = .radial
            // Fading to fully transparent rather than to a darker version of
            // itself. A gradient that ends in colour leaves a visible disc
            // edge; ending in alpha leaves nothing to see.
            gradient.colors = [
                light.colour.withAlphaComponent(Self.intensity).cgColor,
                light.colour.withAlphaComponent(Self.intensity * 0.45).cgColor,
                light.colour.withAlphaComponent(0).cgColor,
            ]
            gradient.locations = Self.stops.map { NSNumber(value: Double($0)) }
            // Screen, so overlapping lights add rather than paint over each
            // other. Normal blending would let the last light drawn win, which
            // is the flat look this is trying to avoid.
            gradient.compositingFilter = "screenBlendMode"
            host.addSublayer(gradient)
            lights.append(gradient)
        }
    }

    override func layout() {
        super.layout()
        // Positioned here rather than on a schedule: these are static lights,
        // so the only time they move is when the panel resizes to fit a
        // proposal.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        base.frame = bounds
        for (gradient, light) in zip(lights, Self.plan) {
            let size = bounds.width * light.radius
            gradient.frame = CGRect(
                x: bounds.width * light.centre.x - size / 2,
                y: bounds.height * light.centre.y - size / 2,
                width: size, height: size)
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 1)
        }
        CATransaction.commit()
    }
}
