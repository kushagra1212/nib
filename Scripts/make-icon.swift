#!/usr/bin/env swift
// Draws the app icon and writes an .iconset, ready for iconutil.
//
// Generated rather than committed as binary art so it can be tweaked in a diff
// and rebuilt reproducibly.
//
//   swift Scripts/make-icon.swift && iconutil -c icns Resources/AppIcon.iconset

import AppKit
import Foundation

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("Resources/AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// Draws a pen nib on a rounded ink-coloured tile.
func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let inset = size * 0.06
    let tile = rect.insetBy(dx: inset, dy: inset)
    let corner = size * 0.225 // macOS squircle proportion

    // Background: deep ink blue, lit from the top.
    let path = NSBezierPath(roundedRect: tile, xRadius: corner, yRadius: corner)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.29, green: 0.44, blue: 0.95, alpha: 1),
        NSColor(calibratedRed: 0.13, green: 0.21, blue: 0.62, alpha: 1),
    ])
    gradient?.draw(in: path, angle: -90)

    // The nib itself: a tapered blade with a central slit and breather hole,
    // which is what makes the silhouette read as a pen rather than an arrow.
    let cx = size / 2
    let top = size * 0.76
    let tip = size * 0.20
    let halfWidth = size * 0.19
    let shoulder = size * 0.52

    // Outline, slit and breather hole are one path filled with the even-odd
    // rule, so the inner shapes cut through to the background. Drawing them
    // separately with destinationOut does not composite inside lockFocus.
    let nib = NSBezierPath()
    nib.move(to: NSPoint(x: cx, y: tip))
    nib.line(to: NSPoint(x: cx - halfWidth, y: shoulder))
    nib.line(to: NSPoint(x: cx - halfWidth * 0.72, y: top))
    nib.line(to: NSPoint(x: cx + halfWidth * 0.72, y: top))
    nib.line(to: NSPoint(x: cx + halfWidth, y: shoulder))
    nib.close()

    // Slit and hole must not overlap. Under the even-odd rule an overlap
    // counts twice and fills back in, which turns the breather hole into a
    // white disc.
    let slitWidth = max(1, size * 0.045)
    let slitTop = size * 0.495
    nib.move(to: NSPoint(x: cx - slitWidth / 2, y: tip + size * 0.075))
    nib.line(to: NSPoint(x: cx - slitWidth / 2, y: slitTop))
    nib.line(to: NSPoint(x: cx + slitWidth / 2, y: slitTop))
    nib.line(to: NSPoint(x: cx + slitWidth / 2, y: tip + size * 0.075))
    nib.close()

    let holeRadius = size * 0.055
    let holeBottom = slitTop + size * 0.022
    nib.appendOval(in: NSRect(x: cx - holeRadius, y: holeBottom,
                              width: holeRadius * 2, height: holeRadius * 2))

    nib.windingRule = .evenOdd
    NSColor.white.setFill()
    nib.fill()

    return image
}

func write(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:])
    else { throw NSError(domain: "icon", code: 1) }
    try png.write(to: url)
}

for size in sizes {
    let image = drawIcon(size: CGFloat(size))
    try write(image, to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    // Retina variant of the next size down.
    if size >= 32 {
        let half = size / 2
        try write(image, to: iconset.appendingPathComponent("icon_\(half)x\(half)@2x.png"))
    }
}

print("wrote \(iconset.path)")
