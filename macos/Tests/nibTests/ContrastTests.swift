import AppKit
import XCTest
@testable import nib

/// Whether nib's own text can be read on nib's own backdrop.
///
/// These panels float over other applications and draw their own dark base, so
/// no system appearance is checking this and no reviewer sees the worst case:
/// the aurora is brightest only where two of its three lights cross, which on a
/// one-line bar is a patch a few points wide.
///
/// Measured there, the palette used to fail. Muted text -- the status line, the
/// writing score, every caption, all of it 11pt -- came to 3.4:1 against the
/// 4.5:1 that text this size needs. The selection tint came to 2.9:1 against
/// the 3:1 a control edge needs.
///
/// The floor is held here rather than in a review note, because the way this
/// breaks is somebody making the aurora prettier.
final class ContrastTests: XCTestCase {

    /// The bar over a selection, with a proposal in it. The smallest text nib
    /// draws sits on the widest spread of aurora, so this is the hard case.
    private let bar = CGSize(width: 440, height: 80)
    /// A setup window. Different proportions move the bright spot, so the
    /// palette is checked against both rather than against one shape.
    private let window = CGSize(width: 420, height: 320)

    private func worst(_ colour: NSColor, in size: CGSize) -> CGFloat {
        Contrast.ratio(colour, on: Contrast.brightestBackdrop(in: size))
    }

    /// Body text, at the brightest point of both surfaces.
    func testBodyTextIsReadableOnTheAurora() {
        for size in [bar, window] {
            XCTAssertGreaterThanOrEqual(
                worst(Theme.Colour.ink, in: size), Contrast.Floor.text,
                "body text fails on \(size.width)x\(size.height)")
        }
    }

    /// The muted colour, which is the one that failed.
    func testMutedTextIsReadableOnTheAurora() {
        for size in [bar, window] {
            XCTAssertGreaterThanOrEqual(
                worst(Theme.Colour.inkMuted, in: size), Contrast.Floor.text,
                "muted text fails on \(size.width)x\(size.height)")
        }
    }

    /// The selection tint marks which control is chosen, so it is held to the
    /// non-text floor rather than left to look right.
    func testTheSelectionTintClearsTheEdgeFloor() {
        for size in [bar, window] {
            XCTAssertGreaterThanOrEqual(
                worst(Theme.Colour.selection, in: size), Contrast.Floor.nonText,
                "selection fails on \(size.width)x\(size.height)")
        }
    }

    /// The colours that carry meaning: wrong, suggestion, accepted.
    ///
    /// These are read as words -- "looks good", a refusal, a diff -- so they are
    /// held to the text floor, not the edge one.
    func testMeaningfulColoursAreReadable() {
        let meanings: [(String, NSColor)] = [
            ("correction", Theme.Colour.correction),
            ("accept", Theme.Colour.accept),
            ("clarity", Theme.Colour.clarity),
        ]
        for (name, colour) in meanings {
            XCTAssertGreaterThanOrEqual(
                worst(colour, in: bar), Contrast.Floor.text,
                "\(name) is not readable at the aurora's brightest")
        }
    }

    /// The aurora cannot be brightened back without the rest failing.
    ///
    /// Pinned because 0.38 is what it was, and 0.38 is what put muted text
    /// under the floor. Raising it is a decision, not a tweak.
    func testTheAuroraStaysBelowTheIntensityThatBrokeIt() {
        XCTAssertLessThanOrEqual(AuroraBackground.intensity, 0.30)
    }

    /// Sanity on the maths itself, against values that are not in doubt.
    func testTheRatioMathsAgreesWithKnownPairs() {
        let black = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        XCTAssertEqual(Contrast.ratio(white, on: black), 21, accuracy: 0.01)
        XCTAssertEqual(Contrast.ratio(white, on: white), 1, accuracy: 0.001)
    }

    /// The backdrop only ever brightens.
    ///
    /// A screen blend cannot darken, so the base is the floor and the sampled
    /// peak is the ceiling. Worth stating because the first version of this
    /// test asserted the opposite -- that somewhere on the panel no light
    /// reaches -- and there is no such point: three lights of radius 0.55 to
    /// 0.70 across a unit square leave nothing uncovered.
    func testTheBackdropNeverDarkensBelowItsBase() {
        let floor = Contrast.luminance(AuroraBackground.baseColour)
        for x in stride(from: CGFloat(0), through: 1, by: 0.1) {
            for y in stride(from: CGFloat(0), through: 1, by: 0.1) {
                let here = Contrast.backdrop(atX: x, y: y, in: bar)
                XCTAssertGreaterThanOrEqual(Contrast.luminance(here), floor - 0.0001)
            }
        }
        XCTAssertGreaterThan(
            Contrast.luminance(Contrast.brightestBackdrop(in: bar)), floor)
    }
}
