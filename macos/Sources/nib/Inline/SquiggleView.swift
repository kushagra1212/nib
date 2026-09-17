import AppKit

/// Marks flagged text: a soft tinted highlight plus a clean underline.
///
/// Colours follow the convention Grammarly established, so the meaning is
/// already familiar: red for spelling and grammar, blue for clarity.
final class SquiggleView: NSView {
    struct Mark {
        let suggestion: Suggestion
        /// One rect per line the suggestion covers, in this view's space.
        /// A sentence-length clarity mark usually wraps, so several.
        let rects: [CGRect]
    }

    var marks: [Mark] = [] {
        didSet {
            fadeIn(from: oldValue)
            needsDisplay = true
        }
    }
    var hovered: UUID? {
        didSet {
            guard oldValue != hovered else { return }
            needsDisplay = true
        }
    }

    private enum Style {
        static let underlineHeight: CGFloat = 2
        static let dropBelow: CGFloat = 1
        static let highlightAlpha: CGFloat = 0.10
        /// Lighter: a clarity mark covers a whole sentence.
        static let clarityHighlightAlpha: CGFloat = 0.055
        static let hoverHighlightAlpha: CGFloat = 0.20
        static let highlightCorner: CGFloat = 2
        static let highlightInset: CGFloat = -1
        /// Long enough to register as a fade, short enough not to feel slow.
        static let fadeDuration: CFTimeInterval = 0.16
    }

    override var isFlipped: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Marks change on every keystroke; caching the rendered layer keeps
        // redraws off the CPU when only the window moves.
        layer?.drawsAsynchronously = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Fades the layer in when marks appear from nothing, so suggestions do
    /// not pop into place mid-sentence.
    private func fadeIn(from previous: [Mark]) {
        guard previous.isEmpty, !marks.isEmpty, let layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = Style.fadeDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "fade")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        for mark in marks {
            let isHovered = mark.suggestion.id == hovered
            let tint: NSColor = mark.suggestion.kind == .correction
                ? .systemRed
                : .systemBlue
            let baseAlpha = mark.suggestion.kind == .correction
                ? Style.highlightAlpha
                : Style.clarityHighlightAlpha

            for rect in mark.rects where rect.intersects(dirtyRect) {
                let highlight = rect.insetBy(dx: Style.highlightInset,
                                             dy: Style.highlightInset)
                let path = NSBezierPath(roundedRect: highlight,
                                        xRadius: Style.highlightCorner,
                                        yRadius: Style.highlightCorner)
                tint.withAlphaComponent(
                    isHovered ? Style.hoverHighlightAlpha : baseAlpha
                ).setFill()
                path.fill()

                context.setFillColor(
                    tint.withAlphaComponent(isHovered ? 1.0 : 0.7).cgColor)
                context.fill(CGRect(x: rect.minX,
                                    y: rect.minY - Style.dropBelow,
                                    width: rect.width,
                                    height: Style.underlineHeight))
            }
        }
    }

    /// The suggestion under a point, if any.
    ///
    /// Marks are searched in order, and corrections are inserted first, so a
    /// word-level fix wins over the clarity mark covering the same sentence.
    func suggestion(at point: CGPoint) -> Mark? {
        marks.first { mark in
            mark.rects.contains { $0.insetBy(dx: -2, dy: -4).contains(point) }
        }
    }

    /// Rect to anchor the card to, for a given suggestion.
    func anchorRect(for id: UUID) -> CGRect? {
        marks.first { $0.suggestion.id == id }?.rects.first
    }
}
