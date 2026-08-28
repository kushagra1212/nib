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
        /// Lighter: a clarity mark covers a whole sentence.
        static let clarityHighlightAlpha: CGFloat = 0.06
        static let hoverHighlightAlpha: CGFloat = 0.20
        static let highlightCorner: CGFloat = 2
        static let highlightInset: CGFloat = -1
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        for mark in marks {
            let isHovered = mark.suggestion.id == hovered
            // Errors read as red; clarity is advice, not a mistake, so it gets
            // a calmer blue. Marking both the same way turns taste into an
            // error report.
            let tint: NSColor = mark.suggestion.kind == .correction
                ? .systemRed
                : .systemBlue

            let highlight = mark.rect.insetBy(dx: Style.highlightInset,
                                              dy: Style.highlightInset)
            let path = NSBezierPath(roundedRect: highlight,
                                    xRadius: Style.highlightCorner,
                                    yRadius: Style.highlightCorner)
            // A clarity mark spans a whole sentence, so its tint is lighter;
            // at sentence width the error tint would read as a highlighter.
            let baseAlpha = mark.suggestion.kind == .correction
                ? Style.highlightAlpha
                : Style.clarityHighlightAlpha
            tint.withAlphaComponent(
                isHovered ? Style.hoverHighlightAlpha : baseAlpha
            ).setFill()
            path.fill()

            context.setFillColor(tint.withAlphaComponent(isHovered ? 1.0 : 0.7).cgColor)
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
