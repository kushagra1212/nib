import AppKit

/// Shared look for every surface nib draws.
///
/// Centralised because the panel, the hover card and the selection bar are the
/// same product seen three ways, and they had drifted into three different
/// paddings, radii and button styles.
enum Theme {
    enum Radius {
        static let window: CGFloat = 12
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

    enum Colour {
        static let correction = NSColor.systemRed
        static let clarity = NSColor.systemBlue
        static let accept = NSColor.systemGreen
        static let removed = NSColor.systemRed
        static let added = NSColor.systemGreen

        /// Fill for a quiet control, which has to work on both appearances.
        static var controlFill: NSColor {
            NSColor.controlColor.withAlphaComponent(0.55)
        }
        static var controlHover: NSColor {
            NSColor.controlColor.withAlphaComponent(0.95)
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

    /// Builds the blurred, rounded backdrop every surface sits on.
    static func makeBackground() -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = Radius.window
        view.layer?.cornerCurve = .continuous
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        view.layer?.masksToBounds = true
        return view
    }

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
