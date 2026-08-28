import AppKit

/// Draws wavy underlines under the ranges harper flagged.
final class SquiggleView: NSView {
    struct Mark {
        let suggestion: Suggestion
        /// Rect in this view's coordinate space.
        let rect: CGRect
    }

    var marks: [Mark] = [] { didSet { needsDisplay = true } }
    var hovered: UUID? { didSet { needsDisplay = true } }

    private enum Wave {
        /// Peak-to-peak height of the squiggle.
        static let amplitude: CGFloat = 1.6
        /// Horizontal distance per full period.
        static let wavelength: CGFloat = 5
        static let thickness: CGFloat = 1.6
        /// Gap between the text baseline and the squiggle.
        static let dropBelow: CGFloat = 1
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.setLineWidth(Wave.thickness)
        context.setLineCap(.round)

        for mark in marks {
            let isHovered = mark.suggestion.id == hovered
            let colour: NSColor = isHovered ? .systemOrange : .systemRed
            context.setStrokeColor(colour.cgColor)

            let y = mark.rect.minY - Wave.dropBelow
            context.move(to: CGPoint(x: mark.rect.minX, y: y))

            // Sine drawn as short segments; a real curve is not worth the cost
            // at this size and redraws happen on every keystroke.
            var x = mark.rect.minX
            while x < mark.rect.maxX {
                let phase = (x - mark.rect.minX) / Wave.wavelength * 2 * .pi
                context.addLine(to: CGPoint(x: x, y: y + sin(phase) * Wave.amplitude))
                x += 1
            }
            context.strokePath()
        }
    }

    /// The suggestion under a point, if any. Hit area is padded upward so the
    /// word itself is hoverable, not just the two-pixel squiggle.
    func suggestion(at point: CGPoint) -> Mark? {
        marks.first { mark in
            mark.rect.insetBy(dx: -2, dy: -4).contains(point)
        }
    }
}
