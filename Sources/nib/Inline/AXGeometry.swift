import AppKit
import ApplicationServices

/// Converts between Accessibility screen coordinates and Cocoa's.
///
/// The two disagree about which way is up. AX reports rects with the origin at
/// the TOP-left of the primary display and y growing downward; NSWindow and
/// NSScreen put the origin at the BOTTOM-left with y growing upward. Drawing an
/// AX rect without converting puts it off-screen, mirrored about the middle of
/// the display, which looks exactly like "the overlay does not work".
enum AXGeometry {
    /// Height of the primary display, which both coordinate systems hinge on.
    ///
    /// The primary screen is the one whose frame origin is (0,0), not
    /// necessarily `NSScreen.main` (that is whichever has key focus).
    static var primaryHeight: CGFloat {
        let primary = NSScreen.screens.first { $0.frame.origin == .zero }
        return (primary ?? NSScreen.screens.first)?.frame.height ?? 0
    }

    /// Flips an AX rect into Cocoa screen coordinates.
    static func toCocoa(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.origin.x,
               y: primaryHeight - rect.origin.y - rect.height,
               width: rect.width,
               height: rect.height)
    }

    /// Tallest a single line of text is assumed to be.
    ///
    /// A reported box taller than this covers more than one line, because AX
    /// returns one bounding box for a range that wraps.
    private static let maxLineHeight: CGFloat = 40

    /// Screen rects for each suggestion, in Cocoa coordinates.
    ///
    /// A suggestion can produce SEVERAL rects, one per line it covers. That
    /// matters for clarity suggestions, which span whole sentences and
    /// therefore wrap constantly: an earlier version asked for one box per
    /// range and discarded anything too tall, which silently threw away every
    /// wrapped sentence and left clarity marks invisible.
    static func rects(
        for suggestions: [Suggestion], in element: AXElement
    ) -> [(suggestion: Suggestion, rects: [CGRect])] {
        var out: [(Suggestion, [CGRect])] = []
        for suggestion in suggestions {
            let lines = lineRects(for: suggestion.range, in: element)
            guard !lines.isEmpty else { continue }
            out.append((suggestion, lines))
        }
        return out
    }

    /// One rect per line the range covers.
    ///
    /// Splits a range that reports a multi-line box in half and recurses, which
    /// costs a handful of AX calls per wrapped range rather than one per
    /// character.
    static func lineRects(
        for range: NSRange, in element: AXElement, depth: Int = 0
    ) -> [CGRect] {
        guard range.length > 0, depth < 8 else { return [] }

        let cfRange = CFRange(location: range.location, length: range.length)
        guard let axRect = element.bounds(forRange: cfRange),
              axRect.width > 0, axRect.height > 0
        else { return [] }

        if axRect.height <= maxLineHeight {
            return [toCocoa(axRect)]
        }

        // Spans more than one line: split and let each half resolve itself.
        let half = range.length / 2
        guard half > 0 else { return [] }
        let left = NSRange(location: range.location, length: half)
        let right = NSRange(location: range.location + half, length: range.length - half)

        return merge(lineRects(for: left, in: element, depth: depth + 1)
                     + lineRects(for: right, in: element, depth: depth + 1))
    }

    /// Joins rects that sit on the same line into one, so a split range does
    /// not draw as several abutting underlines with seams between them.
    private static func merge(_ rects: [CGRect]) -> [CGRect] {
        guard rects.count > 1 else { return rects }
        var byLine: [CGFloat: CGRect] = [:]

        for rect in rects {
            // Round the baseline so sub-pixel differences do not split a line.
            let key = (rect.origin.y * 2).rounded() / 2
            if let existing = byLine[key] {
                byLine[key] = existing.union(rect)
            } else {
                byLine[key] = rect
            }
        }
        return byLine.values.sorted { $0.origin.y > $1.origin.y }
    }

    /// Screen rect of the whole text field, in Cocoa coordinates.
    static func frame(of element: AXElement) -> CGRect? {
        guard let position = element.value(for: kAXPositionAttribute),
              let size = element.value(for: kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }

        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent)
        else { return nil }

        return toCocoa(CGRect(origin: point, size: extent))
    }
}
