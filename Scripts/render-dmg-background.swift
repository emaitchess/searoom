#!/usr/bin/env swift

import AppKit
import CoreText
import Foundation

/// Renders the disk-image background: `background.png` and `background@2x.png`.
///
/// The geometry is declared once in y-down space and shared by every element, the
/// way `render-icon.swift` does, so the two scales cannot drift. The composition
/// restates the mark's waterline: paper above, a dithered field below, with the
/// install gesture happening in the clear space that represents remaining
/// capacity.
///
/// Usage: `Scripts/render-dmg-background.swift [output-directory]` (defaults to `dist`).
enum Background {
    /// Must match the Finder window's content size exactly or the picture tiles.
    static let width: CGFloat = 640
    static let height: CGFloat = 400

    /// Icon centres, matching the positions release.sh gives Finder.
    static let appIcon = CGPoint(x: 170, y: 170)
    static let applicationsIcon = CGPoint(x: 470, y: 170)

    static let waterline: CGFloat = 300
    static let rule = CGRect(x: 0, y: 300, width: 640, height: 1)

    /// The same 8-per-64 lattice the website uses, so the two surfaces read as
    /// one system. Dots stay one pixel: this is texture, never a fill.
    static let ditherTile: CGFloat = 8
    static let ditherDots: [CGPoint] = [
        CGPoint(x: 0, y: 0), CGPoint(x: 4, y: 0),
        CGPoint(x: 2, y: 2), CGPoint(x: 6, y: 2),
        CGPoint(x: 0, y: 4), CGPoint(x: 4, y: 4),
        CGPoint(x: 2, y: 6), CGPoint(x: 6, y: 6)
    ]

    /// Arrow from the app toward Applications, drawn as a dashed shaft and a
    /// solid head so it stays crisp at both scales.
    static let arrowY: CGFloat = 170
    static let arrowStart: CGFloat = 248
    static let arrowEnd: CGFloat = 392
    static let arrowDash: CGFloat = 7
    static let arrowGap: CGFloat = 6
    static let arrowThickness: CGFloat = 2
    static let arrowHead: CGFloat = 13

    static let paper = NSColor(calibratedRed: 0xEE / 255, green: 0xEA / 255, blue: 0xDF / 255, alpha: 1)
    static let ink = NSColor(calibratedRed: 0x15 / 255, green: 0x16 / 255, blue: 0x13 / 255, alpha: 1)
    static let secondary = NSColor(calibratedRed: 0x59 / 255, green: 0x59 / 255, blue: 0x59 / 255, alpha: 1)
}

func departureMono(size: CGFloat) -> NSFont {
    let bundled = URL(fileURLWithPath: "Sources/Searoom/Resources/Fonts/DepartureMono-Regular.otf")
    if FileManager.default.fileExists(atPath: bundled.path) {
        CTFontManagerRegisterFontsForURL(bundled as CFURL, .process, nil)
    }
    return NSFont(name: "Departure Mono", size: size)
        ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
}

/// Draws text positioned in the shared y-down space. Glyphs are drawn outside the
/// flip that the shapes use, because flipping the context mirrors them; the y
/// coordinate is converted here instead so callers keep using one coordinate space.
func draw(_ text: String, topLeftY y: CGFloat, x: CGFloat, size: CGFloat, color: NSColor, centered: Bool) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: departureMono(size: size),
        .foregroundColor: color,
        .kern: size * 0.08
    ]
    let string = NSAttributedString(string: text, attributes: attributes)
    let measured = string.size()
    let origin = NSPoint(
        x: centered ? x - measured.width / 2 : x,
        y: Background.height - y - measured.height
    )
    string.draw(at: origin)
}

func render(scale: CGFloat) -> NSBitmapImageRep? {
    let pixelsWide = Int(Background.width * scale)
    let pixelsHigh = Int(Background.height * scale)
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelsWide,
        pixelsHigh: pixelsHigh,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }
    bitmap.size = NSSize(width: Background.width, height: Background.height)

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current?.shouldAntialias = false

    // Adopt the shared y-down geometry rather than restating every coordinate.
    let flip = NSAffineTransform()
    flip.translateX(by: 0, yBy: Background.height)
    flip.scaleX(by: 1, yBy: -1)
    flip.concat()

    Background.paper.setFill()
    NSRect(x: 0, y: 0, width: Background.width, height: Background.height).fill()

    // The field occupies the space below the waterline, as on the mark.
    Background.ink.withAlphaComponent(0.20).setFill()
    var tileY = Background.waterline
    while tileY < Background.height {
        var tileX: CGFloat = 0
        while tileX < Background.width {
            for dot in Background.ditherDots {
                NSRect(x: tileX + dot.x, y: tileY + dot.y, width: 1, height: 1).fill()
            }
            tileX += Background.ditherTile
        }
        tileY += Background.ditherTile
    }

    Background.ink.withAlphaComponent(0.55).setFill()
    Background.rule.fill()

    Background.ink.withAlphaComponent(0.55).setFill()
    var dashX = Background.arrowStart
    while dashX + Background.arrowDash <= Background.arrowEnd - Background.arrowHead {
        NSRect(
            x: dashX,
            y: Background.arrowY - Background.arrowThickness / 2,
            width: Background.arrowDash,
            height: Background.arrowThickness
        ).fill()
        dashX += Background.arrowDash + Background.arrowGap
    }

    let head = NSBezierPath()
    head.move(to: NSPoint(x: Background.arrowEnd, y: Background.arrowY))
    head.line(to: NSPoint(x: Background.arrowEnd - Background.arrowHead, y: Background.arrowY - Background.arrowHead / 2))
    head.line(to: NSPoint(x: Background.arrowEnd - Background.arrowHead, y: Background.arrowY + Background.arrowHead / 2))
    head.close()
    head.fill()

    // Shapes are done; leave the flipped space so glyphs are not mirrored.
    NSGraphicsContext.restoreGraphicsState()

    draw("SEAROOM · LOCAL SYSTEM TELEMETRY", topLeftY: 28, x: 32, size: 11,
         color: Background.secondary, centered: false)
    draw("DRAG SEAROOM TO APPLICATIONS", topLeftY: 258, x: Background.width / 2, size: 12,
         color: Background.secondary, centered: true)
    draw("MACOS 14+ · APPLE SILICON · SIGNED AND NOTARIZED",
         topLeftY: 340, x: Background.width / 2, size: 10,
         color: Background.secondary, centered: true)

    return bitmap
}

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dist"
let output = URL(fileURLWithPath: outputDirectory, isDirectory: true)
let staging = FileManager.default.temporaryDirectory
    .appendingPathComponent("Searoom-\(UUID().uuidString).dmg-stage", isDirectory: true)

do {
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: staging) }

    // Stage both scales and publish only once both succeed, so a failure cannot
    // leave one resolution updated against a stale other.
    for (name, scale) in [("background.png", CGFloat(1)), ("background@2x.png", CGFloat(2))] {
        guard let bitmap = render(scale: scale),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            fputs("Failed to render \(name)\n", stderr)
            exit(EXIT_FAILURE)
        }
        try data.write(to: staging.appendingPathComponent(name), options: .atomic)
    }

    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for name in ["background.png", "background@2x.png"] {
        let data = try Data(contentsOf: staging.appendingPathComponent(name))
        try data.write(to: output.appendingPathComponent(name), options: .atomic)
    }
} catch {
    fputs("Failed to write disk-image background: \(error)\n", stderr)
    exit(EXIT_FAILURE)
}

print("Wrote background.png and background@2x.png to \(output.path)")
