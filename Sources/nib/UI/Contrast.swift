import AppKit

/// WCAG contrast, and how bright the aurora is allowed to get beneath text.
///
/// nib draws its own backdrop rather than borrowing the system's, which means
/// nothing else is checking whether the text on top of it can be read. It could
/// not, in places: where the violet and the blue lights overlap, the muted text
/// used for captions, the status line and the writing score fell to 3.4:1 and
/// the selection tint to 2.9:1. Both are below the floor -- 4.5:1 for text this
/// size, 3:1 for a control's edge -- and the failure is invisible while writing
/// the code, because it only appears on the part of the panel where two
/// gradients happen to cross.
///
/// So the brightness is computed here instead of judged by eye, from the same
/// constants the layers are built from, and `ContrastTests` holds it to the
/// floor.
///
/// **This models the gradient; it does not read pixels.** It reproduces the
/// three lights, their alpha stops and the screen blend, which is what decides
/// the result, but a screenshot is the only thing that proves the render. It is
/// used as a floor -- if the model says a pairing fails, it fails.
enum Contrast {

    /// Relative luminance, per WCAG 2.
    static func luminance(_ colour: NSColor) -> CGFloat {
        guard let srgb = colour.usingColorSpace(.sRGB) else { return 0 }
        func channel(_ value: CGFloat) -> CGFloat {
            value <= 0.03928 ? value / 12.92
                             : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(srgb.redComponent)
             + 0.7152 * channel(srgb.greenComponent)
             + 0.0722 * channel(srgb.blueComponent)
    }

    /// The ratio between two colours, from 1 (identical) to 21 (black on white).
    static func ratio(_ one: NSColor, on other: NSColor) -> CGFloat {
        let a = luminance(one), b = luminance(other)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// What WCAG asks for. Named, because "4.5" on its own in an assertion says
    /// nothing about which rule is being kept.
    enum Floor {
        /// Body and caption text.
        static let text: CGFloat = 4.5
        /// Large text, and the edge of a control -- anything that is not read
        /// as words.
        static let nonText: CGFloat = 3.0
    }

    // MARK: - The aurora beneath

    /// The backdrop colour at one point of a panel, as a fraction of its size.
    ///
    /// Each light is a radial gradient whose alpha runs from `intensity` at the
    /// centre, through `intensity * 0.45` at the middle stop, to nothing at the
    /// rim, composited with a screen blend so overlaps add rather than replace.
    static func backdrop(atX x: CGFloat, y: CGFloat, in size: CGSize) -> NSColor {
        guard size.width > 0, size.height > 0,
              let base = AuroraBackground.baseColour.usingColorSpace(.sRGB)
        else { return AuroraBackground.baseColour }

        var red = base.redComponent
        var green = base.greenComponent
        var blue = base.blueComponent

        for light in AuroraBackground.plan {
            guard let hue = light.colour.usingColorSpace(.sRGB) else { continue }
            // The layer is square and sized from the width, so the distance is
            // measured in width-relative units in both axes.
            let dx = x - light.centre.x
            let dy = (y - light.centre.y) * (size.height / size.width)
            let distance = (dx * dx + dy * dy).squareRoot()
            let alpha = alphaAt(distance: distance, radius: light.radius)
            guard alpha > 0 else { continue }

            func screen(_ backdrop: CGFloat, _ source: CGFloat) -> CGFloat {
                let blended = 1 - (1 - backdrop) * (1 - source)
                return backdrop * (1 - alpha) + alpha * blended
            }
            red = screen(red, hue.redComponent)
            green = screen(green, hue.greenComponent)
            blue = screen(blue, hue.blueComponent)
        }
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    /// The brightest the backdrop gets anywhere on a panel of this size.
    ///
    /// Sampled rather than solved. The maximum sits wherever two lights happen
    /// to cross, which moves with the panel's proportions -- a tall setup
    /// window and a one-line bar do not have their bright spot in the same
    /// place, and the bar is the one that matters because its text is smallest.
    static func brightestBackdrop(in size: CGSize, step: CGFloat = 4) -> NSColor {
        var brightest = AuroraBackground.baseColour
        var highest = luminance(brightest)
        var down: CGFloat = 0
        while down <= size.height {
            var across: CGFloat = 0
            while across <= size.width {
                let here = backdrop(atX: across / size.width,
                                    y: down / size.height, in: size)
                let level = luminance(here)
                if level > highest {
                    highest = level
                    brightest = here
                }
                across += step
            }
            down += step
        }
        return brightest
    }

    /// Alpha at a distance from a light's centre, interpolating the stops.
    private static func alphaAt(distance: CGFloat, radius: CGFloat) -> CGFloat {
        let peak = AuroraBackground.intensity
        let alphas: [CGFloat] = [peak, peak * 0.45, 0]
        let stops = AuroraBackground.stops
        let travelled = distance / radius
        guard travelled < stops[stops.count - 1] else { return 0 }

        for index in 1..<stops.count where travelled <= stops[index] {
            let span = stops[index] - stops[index - 1]
            guard span > 0 else { return alphas[index] }
            let progress = (travelled - stops[index - 1]) / span
            return alphas[index - 1]
                + (alphas[index] - alphas[index - 1]) * progress
        }
        return 0
    }
}
