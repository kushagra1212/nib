import AppKit

/// Shared look for every surface nib draws.
///
/// Centralised because the panel, the hover card and the selection bar are the
/// same product seen three ways, and they had drifted into three different
/// paddings, radii and button styles.
enum Theme {
    /// Neoclassical: order, proportion, and no ornament that is not structural.
    ///
    /// The style is not paint. Classical architecture is built from a small set
    /// of repeated members at fixed proportions, and the equivalent here is one
    /// control height, one radius, one hairline, one face -- so a button in the
    /// rewrite bar and a button in the setup window are the same object rather
    /// than two things that happen to be the same colour.
    ///
    /// Capsules are gone with the rest of it. A pill is a shape from a different
    /// tradition, and it was also the reason the strength dial could never be
    /// made to match its neighbours: AppKit has no capsule segmented control.
    enum Metric {
        /// Every control is this tall. No exceptions -- a row of differing
        /// heights is what made the old bar read as assembled parts.
        static let control: CGFloat = 24
        /// Padding inside a control, left and right.
        static let controlPadding: CGFloat = 12
        /// One hairline, everywhere something needs an edge.
        static let hairline: CGFloat = 1
        /// Gap between a glyph and its label.
        static let glyphGap: CGFloat = 5
    }

    enum Radius {
        /// Shallow, and the same on every surface. Classical corners are close
        /// to square; the small radius is a concession to the display, not a
        /// style choice.
        static let window: CGFloat = 6
        static let control: CGFloat = 3
        /// Retained under its old name so nothing has to be renamed to be
        /// corrected. It is no longer a pill.
        static let pill: CGFloat = 3
    }

    enum Space {
        static let edge: CGFloat = 12
        static let row: CGFloat = 8
        static let tight: CGFloat = 4
    }

    enum Motion {
        /// Everything stays under a fifth of a second. Long enough to read as
        /// motion, short enough that it never delays reaching a button.
        static let appear: TimeInterval = 0.15
        static let dismiss: TimeInterval = 0.10
        static let content: TimeInterval = 0.18
        static let hover: TimeInterval = 0.09
        static let rise: CGFloat = 7

        static var easeOut: CAMediaTimingFunction {
            CAMediaTimingFunction(name: .easeOut)
        }
        /// Slight overshoot, so a card arriving feels placed rather than drawn.
        static var settle: CAMediaTimingFunction {
            CAMediaTimingFunction(controlPoints: 0.17, 0.89, 0.32, 1.06)
        }
    }

    /// Pigments, not system colours.
    ///
    /// Every surface nib draws sits on top of somebody else's work, most of it
    /// text. The system palette is built to be noticed -- systemRed and
    /// systemBlue at full saturation next to a paragraph pull the eye off the
    /// sentence being written, which is the one thing these surfaces must not
    /// do.
    ///
    /// So the accents are named after where they come from: Pompeian red,
    /// verdigris, Wedgwood blue, brass. Meaning is carried by hue rather than
    /// by loudness -- red still reads as wrong and blue still reads as
    /// suggestion, at a fraction of the volume.
    enum Colour {
        /// Builds a colour that shifts with the system appearance.
        private static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
            NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? dark : light
            }
        }

        private static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
            NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                    green: CGFloat((value >> 8) & 0xFF) / 255,
                    blue: CGFloat(value & 0xFF) / 255,
                    alpha: alpha)
        }

        // MARK: - Pigments

        /// Pompeian red, the pigment on the walls at Herculaneum. Where the
        /// system would use red.
        static let clay = hex(0xFF7A7A)
        /// Verdigris, aged bronze. Where the system would use green.
        static let sage = hex(0x4FE3C1)
        /// Wedgwood blue. Where the system would use blue.
        static let slate = hex(0x6FB4FF)
        /// Brass. The accent that holds the rest together, used for edges and
        /// selection rather than for fills -- gilding is a line, not a slab.
        static let taupe = hex(0xB48CFF)
        static var brass: NSColor { taupe }

        /// Ivory and ink. Never pure white or pure black: marble is warm and
        /// printer's ink is not carbon.
        static let ivory = adaptive(light: hex(0xF6F2E9), dark: hex(0x1C1B19))

        // MARK: - Meaning

        static let correction = clay
        static let clarity = slate
        static let accept = sage
        static let removed = clay
        static let added = sage
        /// The recording indicator. Clay rather than red: it has to be
        /// unmissable without being an alarm.
        static let listening = clay

        /// Per-mode icon colour, so the row is distinguishable at a glance and
        /// carries some warmth rather than reading as four grey chips.
        static let fix = sage
        static let rewrite = slate
        static let condense = taupe

        /// Text, in two weights. Warm rather than neutral grey, and never pure
        /// black on white or white on black -- the contrast is what makes a
        /// small floating panel feel like a system alert.
        /// Fixed, not adaptive. The panels carry their own dark base now, so
        /// text sits on aurora rather than on the system's background, and
        /// switching to light mode must not turn it dark-on-dark.
        static let ink = hex(0xF2F5F7)
        static let inkMuted = hex(0x9FB0BC)

        /// The single edge colour. One hairline, one weight, everywhere.
        static let rule = hex(0xFFFFFF, alpha: 0.14)

        /// The tint used for a selected control. Replaces the system accent,
        /// which is whatever colour the user picked in System Settings and so
        /// cannot be made to sit with anything else.
        static let selection = taupe

        /// Fill for a quiet control.
        ///
        /// Layered light-on-dark or dark-on-light rather than `controlColor`,
        /// which is nearly invisible against a blurred backdrop and left the
        /// capsules looking like hollow outlines.
        static func controlFill(_ opacity: CGFloat) -> NSColor {
            NSColor(white: 1, alpha: opacity)
        }

        /// Edge that separates a control from whatever shows through behind it.
        static func controlEdge(_ opacity: CGFloat) -> NSColor {
            NSColor(white: 1, alpha: opacity)
        }
}

    enum Font {
        /// New York, Apple's serif. The clearest signal of the style and the
        /// cheapest: it ships with the system, so nothing is bundled and
        /// nothing falls back to Times.
        private static func serif(_ size: CGFloat,
                                  _ weight: NSFont.Weight = .regular) -> NSFont {
            let base = NSFont.systemFont(ofSize: size, weight: weight)
            guard let descriptor = base.fontDescriptor
                .withDesign(.serif) else { return base }
            return NSFont(descriptor: descriptor, size: size) ?? base
        }

        static let body = serif(13)
        static let diff = serif(14)
        static let diffEmphasis = serif(14, .semibold)
        static let control = serif(11, .medium)
        static let caption = serif(11)
        static let title = serif(11, .semibold)
        /// A window heading. The only size above body text, and still serif --
        /// a sans-serif heading over serif prose is the drift this file exists
        /// to prevent, and a screenshot caught it doing exactly that.
        static let heading = serif(15, .semibold)
        /// A row's name, one step up from body.
        static let rowTitle = serif(13, .medium)
    }

    /// The mark that says a model wrote what follows.
    ///
    /// Two letters and a space rather than a pill or a row of its own: it has
    /// to sit inside a card small enough to float over someone's text, and it
    /// is a note about provenance, not a heading.
    static func aiTag() -> NSAttributedString {
        NSAttributedString(string: "AI  ", attributes: [
            .foregroundColor: Colour.rewrite,
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
        ])
    }

    /// Builds the blurred, rounded backdrop every surface sits on.
    ///
    /// `hudWindow` is the material Apple names for floating heads-up windows,
    /// which is what these are, and it is considerably more translucent than
    /// `popover` -- which read as a solid dark slab sitting on the text rather
    /// than something hovering over it.
    static func makeBackground() -> NSVisualEffectView {
        let view = GlassBackground()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        // Emphasis darkens the material to mark a focused window. These float
        // above someone else's text and should stay light.
        view.isEmphasized = false
        view.wantsLayer = true
        view.layer?.cornerRadius = Radius.window
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true

        // The aurora goes inside the blur, beneath whatever the caller adds
        // next. Every panel gets it from this one call, so no surface can be
        // left on the old flat backdrop by omission.
        let aurora = makeAurora()
        aurora.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(aurora)
        NSLayoutConstraint.activate([
            aurora.topAnchor.constraint(equalTo: view.topAnchor),
            aurora.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            aurora.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            aurora.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        return view
    }

    /// The aurora itself: a dark base with three coloured lights behind the
    /// glass.
    ///
    /// Aurora needs a dark base to glow against -- over a light background
    /// there is nothing for the colour to read as light against, and it dies.
    /// nib's panels float over other people's documents, which may be any
    /// colour, so each panel supplies its own base rather than relying on
    /// what is behind it. That is also what makes this work in light mode.
    ///
    /// Three hues, not more. Overlapping gradients mix subtractively on screen
    /// and a fourth or fifth turns the whole thing brown, which is the usual
    /// way this effect is got wrong.
    ///
    /// Static, deliberately. The style is normally animated over eight to
    /// twelve seconds, and a slow colour drift behind a bar that sits on top of
    /// a sentence someone is writing is movement in the corner of the eye with
    /// nothing to say.
    static func makeAurora() -> NSView {
        let view = AuroraBackground()
        view.wantsLayer = true
        view.layer?.cornerRadius = Radius.window
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        return view
    }
}

/// The backdrop, with the two edges that make a translucent surface read as
/// glass rather than as a hole.
///
/// A single flat border looks drawn on. Real material has a bright rim along
/// the top, where light catches the edge, and a darker one below it.
final class GlassBackground: NSVisualEffectView {
    private let rim = CAShapeLayer()

    override func layout() {
        super.layout()
        guard let layer else { return }

        if rim.superlayer == nil {
            rim.fillColor = nil
            rim.lineWidth = 1
            layer.addSublayer(rim)
        }
        let inset = bounds.insetBy(dx: 0.5, dy: 0.5)
        rim.frame = bounds
        rim.path = CGPath(roundedRect: inset,
                          cornerWidth: Theme.Radius.window,
                          cornerHeight: Theme.Radius.window,
                          transform: nil)
        refreshRim()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshRim()
    }

    private func refreshRim() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            rim.strokeColor = dark
                ? NSColor(white: 1, alpha: 0.16).cgColor
                : NSColor(white: 0, alpha: 0.10).cgColor
        }
    }
}

extension Theme {
    /// Fades and lifts a window into place.
    static func present(_ window: NSWindow, at target: NSRect) {
        window.setFrame(
            NSRect(x: target.origin.x, y: target.origin.y - Motion.rise,
                   width: target.width, height: target.height),
            display: false)
        window.alphaValue = 0
        window.orderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.appear
            context.timingFunction = Motion.settle
            window.animator().alphaValue = 1
            window.animator().setFrame(target, display: true)
        }
    }

    /// Fades a window out, then orders it away once invisible.
    static func dismiss(_ window: NSWindow) {
        guard window.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.dismiss
            context.timingFunction = Motion.easeOut
            window.animator().alphaValue = 0
        } completionHandler: {
            guard window.alphaValue < 0.05 else { return }
            window.orderOut(nil)
            window.alphaValue = 1
        }
    }

    /// Resizes a window from its top edge, so content growing downwards does
    /// not appear to shove the whole surface up the screen.
    static func resize(_ window: NSWindow, to size: NSSize, animated: Bool = true) {
        var frame = window.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        guard animated, window.isVisible else {
            window.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.content
            context.timingFunction = Motion.easeOut
            window.animator().setFrame(frame, display: true)
        }
    }
}
