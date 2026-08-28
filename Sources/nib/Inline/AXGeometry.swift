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

    /// Screen rects for each suggestion, in Cocoa coordinates.
    ///
    /// Ranges that report no bounds are dropped rather than guessed at: a
    /// squiggle in the wrong place is worse than no squiggle.
    static func rects(
        for suggestions: [Suggestion], in element: AXElement
    ) -> [(suggestion: Suggestion, rect: CGRect)] {
        var out: [(Suggestion, CGRect)] = []
        for suggestion in suggestions {
            let cfRange = CFRange(location: suggestion.range.location,
                                  length: suggestion.range.length)
            guard let axRect = element.bounds(forRange: cfRange),
                  axRect.width > 0, axRect.height > 0
            else { continue }

            // A range that wraps across lines comes back as one tall box
            // covering the span. Underlining that whole block is wrong, so
            // skip it; the panel still offers the fix.
            guard axRect.height < 60 else { continue }

            out.append((suggestion, toCocoa(axRect)))
        }
        return out
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
