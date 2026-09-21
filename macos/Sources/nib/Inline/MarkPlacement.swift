import Foundation

/// Positions marks relative to the overlay window.
///
/// Split out from the drawing code so it can be tested without a screen. The
/// failures it guards against are all silent: a mark drawn at a stale offset
/// still looks like a mark, just under the wrong words.
enum MarkPlacement {
    /// Converts screen rects into the overlay window's coordinate space and
    /// drops anything outside the field.
    ///
    /// A scrolled-away line still reports bounds, so without the clip a mark
    /// would be painted over whatever sits above or below the field.
    static func place(
        marks: [(suggestion: Suggestion, rects: [CGRect])],
        fieldFrame: CGRect
    ) -> [(suggestion: Suggestion, rects: [CGRect])] {
        marks.compactMap { mark in
            let visible = mark.rects
                .filter { fieldFrame.intersects($0) }
                .map { clip($0, to: fieldFrame) }
                .filter { $0.width > 0 && $0.height > 0 }
                .map { toWindow($0, fieldFrame: fieldFrame) }
            return visible.isEmpty ? nil : (mark.suggestion, visible)
        }
    }

    /// Trims a rect to the part inside the field, so a half-scrolled line is
    /// underlined only where it is actually visible.
    static func clip(_ rect: CGRect, to fieldFrame: CGRect) -> CGRect {
        rect.intersection(fieldFrame)
    }

    /// Screen coordinates to window coordinates.
    static func toWindow(_ rect: CGRect, fieldFrame: CGRect) -> CGRect {
        CGRect(x: rect.origin.x - fieldFrame.origin.x,
               y: rect.origin.y - fieldFrame.origin.y,
               width: rect.width,
               height: rect.height)
    }
}
