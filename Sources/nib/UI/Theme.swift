import AppKit

/// Shared look for every surface nib draws.
///
/// Centralised because the panel, the hover card and the selection bar are the
/// same product seen three ways, and they had drifted into three different
/// paddings, radii and button styles.
enum Theme {
    enum Radius {
        /// Generous, because a small radius on a translucent panel reads as a
        /// cut-out rather than as a floating surface.
        static let window: CGFloat = 14
        static let control: CGFloat = 7
        static let pill: CGFloat = 9
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

    /// Japandi: Japanese restraint, Scandinavian warmth.
    ///
    /// Every surface nib draws sits on top of somebody else's work, most of it
    /// text. The system palette is built to be noticed -- systemRed and
    /// systemBlue at full saturation next to a paragraph pull the eye off the
    /// sentence being written, which is the one thing these surfaces must not
    /// do.
    ///
    /// So: muted earth pigments on warm neutrals, no pure black, no pure white,
    /// and four accents rather than the six that had accumulated. Meaning is
    /// carried by hue, not by loudness -- clay still reads as wrong and slate
    /// still reads as suggestion, at a fraction of the volume.
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

        /// Burnt clay. Where the system would use red.
        static let clay = adaptive(light: hex(0xA85C48), dark: hex(0xC97F6B))
        /// Soft sage. Where the system would use green.
        static let sage = adaptive(light: hex(0x6F7F5C), dark: hex(0x9DAE88))
        /// Cool slate. Where the system would use blue.
        static let slate = adaptive(light: hex(0x5C7180), dark: hex(0x8FA6B5))
        /// Warm taupe, for the third mode.
        static let taupe = adaptive(light: hex(0x8A7A6D), dark: hex(0xB4A392))

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
        static let ink = adaptive(light: hex(0x2E2A26), dark: hex(0xE8E3DB))
        static let inkMuted = adaptive(light: hex(0x7A7168), dark: hex(0x9E958B))

        /// The tint used for a selected control. Replaces the system accent,
        /// which is whatever colour the user picked in System Settings and so
        /// cannot be made to sit with anything else.
        static let selection = slate

        /// Fill for a quiet control.
        ///
        /// Layered light-on-dark or dark-on-light rather than `controlColor`,
        /// which is nearly invisible against a blurred backdrop and left the
        /// capsules looking like hollow outlines.
        static func controlFill(_ opacity: CGFloat) -> NSColor {
            NSColor(name: nil) { appearance in
                let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return dark
                    ? NSColor(white: 1, alpha: opacity)
                    : NSColor(white: 0, alpha: opacity * 0.55)
            }
        }

        /// Edge that separates a control from whatever shows through behind it.
        static func controlEdge(_ opacity: CGFloat) -> NSColor {
            NSColor(name: nil) { appearance in
                let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return dark
                    ? NSColor(white: 1, alpha: opacity)
                    : NSColor(white: 0, alpha: opacity * 0.7)
            }
        }
    }

    enum Font {
        static let body = NSFont.systemFont(ofSize: 13)
        static let diff = NSFont.systemFont(ofSize: 14)
        static let diffEmphasis = NSFont.boldSystemFont(ofSize: 14)
        static let control = NSFont.systemFont(ofSize: 11, weight: .medium)
        static let caption = NSFont.systemFont(ofSize: 11)
        static let title = NSFont.systemFont(ofSize: 11, weight: .semibold)
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
