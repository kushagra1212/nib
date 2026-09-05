import AppKit
import XCTest
@testable import nib

/// nib's panels do not take their colours from the system, and must not.
///
/// Every surface nib draws paints its own near-black aurora base, in both
/// appearances -- that is deliberate, because these things float over other
/// people's documents and cannot know what is behind them. The consequence is
/// that any system colour used on one is wrong half the time.
///
/// It was wrong. Nine places used `NSColor.labelColor`, which is black at 85%
/// in light mode and measured **1.08:1** against that base: the rewrite
/// suggestion, the diff and the fix card were invisible to anyone not running
/// dark mode. Two more used `controlColor` as a control fill, which in dark
/// mode came to 1.19:1 against the panel and left the control with no visible
/// body at all.
///
/// It survived because the machine it was written on runs dark mode, where
/// `labelColor` is white and everything looks correct. That is why this is a
/// test and not a note: the bug is invisible in the appearance most likely to
/// be in use while working on it.
final class PanelPaletteTests: XCTestCase {

    private var sources: [(path: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // nibTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Sources/nib")
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil) else { return [] }

        var found: [(String, String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            found.append((url.lastPathComponent, text))
        }
        return found
    }

    /// Appearance-dependent system colours, and what to use instead.
    private static let banned: [(token: String, use: String)] = [
        ("NSColor.labelColor", "Theme.Colour.ink"),
        (".labelColor", "Theme.Colour.ink"),
        ("secondaryLabelColor", "Theme.Colour.inkMuted"),
        ("NSColor.controlColor", "Theme.Colour.controlFill"),
        ("NSColor.textColor", "Theme.Colour.ink"),
        ("NSColor.windowBackgroundColor", "Theme.makeBackground"),
    ]

    func testNoSurfaceTakesItsTextColourFromTheSystem() {
        let files = sources
        XCTAssertFalse(files.isEmpty, "found no sources to check")

        var offences: [String] = []
        for (path, text) in files {
            // Theme owns the palette and is allowed to name what it replaces.
            guard path != "Theme.swift", path != "Contrast.swift" else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), !code.hasPrefix("///") else { continue }
                for (token, replacement) in Self.banned where code.contains(token) {
                    offences.append("\(path): \(code) -- use \(replacement)")
                }
            }
        }
        XCTAssertEqual(offences, [], "system colours on nib's own dark panels:\n"
                       + offences.joined(separator: "\n"))
    }

    /// The failure that was there, stated as a number so the reason survives.
    func testTheSystemLabelColourWouldFailOnTheseSurfaces() {
        let base = AuroraBackground.baseColour
        var lightLabel = NSColor.labelColor
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            lightLabel = NSColor.labelColor.usingColorSpace(.sRGB) ?? lightLabel
        }
        // Composited onto the panel nib actually draws.
        let composited = NSColor(
            srgbRed: lightLabel.redComponent * lightLabel.alphaComponent
                + base.redComponent * (1 - lightLabel.alphaComponent),
            green: lightLabel.greenComponent * lightLabel.alphaComponent
                + base.greenComponent * (1 - lightLabel.alphaComponent),
            blue: lightLabel.blueComponent * lightLabel.alphaComponent
                + base.blueComponent * (1 - lightLabel.alphaComponent),
            alpha: 1)
        XCTAssertLessThan(Contrast.ratio(composited, on: base), 1.5,
                          "if this passes, labelColor is no longer the trap "
                          + "this test exists to describe")
        // And what replaced it clears the floor by a wide margin.
        XCTAssertGreaterThan(Contrast.ratio(Theme.Colour.ink, on: base), 15)
    }

    /// The rim is fixed too, for the same reason.
    func testTheRimDoesNotFollowTheSystemAppearance() {
        let panel = Theme.makeBackground()
        panel.frame = NSRect(x: 0, y: 0, width: 300, height: 60)
        panel.layoutSubtreeIfNeeded()

        var strokes: [CGColor] = []
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            panel.appearance = NSAppearance(named: name)
            panel.layout()
            let rim = panel.layer?.sublayers?
                .compactMap { $0 as? CAShapeLayer }.first
            if let colour = rim?.strokeColor { strokes.append(colour) }
        }
        XCTAssertEqual(strokes.count, 2, "expected a rim in both appearances")
        XCTAssertEqual(strokes.first, strokes.last,
                       "the rim changed with the system appearance, but the "
                       + "panel behind it did not")
    }
}
