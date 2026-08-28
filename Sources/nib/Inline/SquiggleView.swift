import AppKit

/// Marks flagged text the way Grammarly does: a soft tinted highlight behind
/// the words plus a clean underline, rather than a jagged squiggle.
///
/// A hard sawtooth reads as an error state and fights the text for attention.
/// A tint plus a straight rule marks the same span while staying quiet enough
/// to keep writing over.
final class SquiggleView: NSView {
    struct Mark {
        let suggestion: Suggestion
        /// Rect in this view's coordinate space.
        let rect: CGRect
    }

    var marks: [Mark] = [] { didSet { needsDisplay = true } }
    var hovered: UUID? { didSet { needsDisplay = true } }

    private enum Style {
        static let underlineHeight: CGFloat = 2
        static let dropBelow: CGFloat = 1
        static let highlightAlpha: CGFloat = 0.10
        static let hoverHighlightAlpha: CGFloat = 0.20
        static let highlightCorner: CGFloat = 2
        static let highlightInset: CGFloat = -1
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        for mark in marks {
            let isHovered = mark.suggestion.id == hovered
            let tint = NSColor.systemRed

            let highlight = mark.rect.insetBy(dx: Style.highlightInset,
                                              dy: Style.highlightInset)
            let path = NSBezierPath(roundedRect: highlight,
                                    xRadius: Style.highlightCorner,
                                    yRadius: Style.highlightCorner)
            tint.withAlphaComponent(
                isHovered ? Style.hoverHighlightAlpha : Style.highlightAlpha
            ).setFill()
            path.fill()

            context.setFillColor(tint.withAlphaComponent(isHovered ? 1.0 : 0.75).cgColor)
            context.fill(CGRect(x: mark.rect.minX,
                                y: mark.rect.minY - Style.dropBelow,
                                width: mark.rect.width,
                                height: Style.underlineHeight))
        }
    }

    /// The suggestion under a point, if any. Padded so the word is hoverable,
    /// not only the two-pixel underline.
    func suggestion(at point: CGPoint) -> Mark? {
        marks.first { $0.rect.insetBy(dx: -2, dy: -4).contains(point) }
    }
}
