#!/usr/bin/env swift

import AppKit
import Foundation

/// Generates the Searoom brand mark: `AppIcon-1024.png`, `searoom-mark.svg`, and `AppIcon.icns`.
///
/// The geometry is declared once, in SVG's y-down coordinate space on a 1024 grid, and is shared by
/// the raster and vector writers so the two cannot drift. The raster writer flips into AppKit's
/// y-up space rather than restating any coordinate.
///
/// Usage: `Scripts/render-icon.swift [output-directory]` (defaults to `Brand`).
enum Mark {
    static let canvas: CGFloat = 1024
    static let body = CGRect(x: 100, y: 100, width: 824, height: 824)

    /// Exponent of the superellipse used for the body. macOS icon silhouettes are continuous-corner
    /// shapes, not circular-arc rounded rectangles, and n=5 matches that curvature closely.
    static let superellipse: Double = 5

    /// The waterline is the vertical centre of both the body and the S's middle stroke, so the
    /// field occupies exactly the lower half and the rule reads as passing through the letter.
    static let rule = CGRect(x: 100, y: 508, width: 824, height: 8)
    static let field = CGRect(x: 100, y: 512, width: 824, height: 412)

    /// Ordered 4x4 Bayer at 25% density resolves to one filled cell in four, so the field is a
    /// regular lattice: a 32-unit cell on a 64-unit pitch. The origin centres it about x=512.
    static let fieldCell: CGFloat = 32
    static let fieldPitch: CGFloat = 64
    static let fieldOrigin = CGPoint(x: 48, y: 548)

    /// Geometric capital S with its middle stroke centred on the waterline.
    static let letter = [
        CGRect(x: 300, y: 272, width: 424, height: 88),
        CGRect(x: 300, y: 360, width: 96, height: 108),
        CGRect(x: 300, y: 468, width: 424, height: 88),
        CGRect(x: 628, y: 556, width: 96, height: 108),
        CGRect(x: 300, y: 664, width: 424, height: 88)
    ]

    /// The field is drawn in ink, so the letter needs a paper clearance. Without it the lattice
    /// fuses with the strokes and crenellates the letter's edges.
    static let clearance: CGFloat = 16

    /// Cells are atomic: one that would collide with the letter's clearance is dropped rather than
    /// clipped, which would leave slivers. Both writers consume this, so they cannot disagree.
    static var fieldCells: [CGRect] {
        let keepOut = letter.map { $0.insetBy(dx: -clearance, dy: -clearance) }
        var cells: [CGRect] = []
        var y = fieldOrigin.y
        while y < field.maxY {
            var x = fieldOrigin.x
            while x < field.maxX {
                let cell = CGRect(x: x, y: y, width: fieldCell, height: fieldCell)
                if cell.minX >= field.minX, !keepOut.contains(where: { $0.intersects(cell) }) {
                    cells.append(cell)
                }
                x += fieldPitch
            }
            y += fieldPitch
        }
        return cells
    }

    /// Mono colourway: ink on warm paper. The mark carries no semantic colour, which keeps status
    /// colour reserved for live telemetry inside the app.
    static let paper = "#EEEADF"
    static let ink = "#151613"
}

func color(_ hex: String) -> NSColor {
    var value: UInt64 = 0
    Scanner(string: String(hex.dropFirst())).scanHexInt64(&value)
    return NSColor(
        calibratedRed: CGFloat((value >> 16) & 0xFF) / 255,
        green: CGFloat((value >> 8) & 0xFF) / 255,
        blue: CGFloat(value & 0xFF) / 255,
        alpha: 1
    )
}

/// Superellipse |x/a|^n + |y/a|^n = 1, sampled densely enough to stay smooth at 1024.
func squircle(in rect: CGRect, n: Double, steps: Int = 1440) -> NSBezierPath {
    let path = NSBezierPath()
    let radius = Double(rect.width) / 2
    let centerX = Double(rect.midX), centerY = Double(rect.midY)
    for step in 0..<steps {
        let angle = Double(step) / Double(steps) * 2 * .pi
        let cosine = cos(angle), sine = sin(angle)
        let point = NSPoint(
            x: centerX + radius * pow(abs(cosine), 2 / n) * (cosine < 0 ? -1 : 1),
            y: centerY + radius * pow(abs(sine), 2 / n) * (sine < 0 ? -1 : 1)
        )
        if step == 0 { path.move(to: point) } else { path.line(to: point) }
    }
    path.close()
    return path
}

func renderMaster() -> NSBitmapImageRep? {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(Mark.canvas),
        pixelsHigh: Int(Mark.canvas),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

    // Adopt the shared y-down geometry instead of restating it.
    let flip = NSAffineTransform()
    flip.translateX(by: 0, yBy: Mark.canvas)
    flip.scaleX(by: 1, yBy: -1)
    flip.concat()

    squircle(in: Mark.body, n: Mark.superellipse).addClip()

    color(Mark.paper).setFill()
    Mark.body.fill()

    color(Mark.ink).setFill()
    for cell in Mark.fieldCells { cell.fill() }
    Mark.rule.fill()

    color(Mark.paper).setFill()
    for part in Mark.letter { part.insetBy(dx: -Mark.clearance, dy: -Mark.clearance).fill() }

    color(Mark.ink).setFill()
    for part in Mark.letter { part.fill() }

    return bitmap
}

func svg() -> String {
    let path = squircle(in: Mark.body, n: Mark.superellipse, steps: 192)
    var commands: [String] = []
    for index in 0..<path.elementCount {
        var points = [NSPoint(x: 0, y: 0), NSPoint(x: 0, y: 0), NSPoint(x: 0, y: 0)]
        if path.element(at: index, associatedPoints: &points) == .lineTo || index == 0 {
            let verb = index == 0 ? "M" : "L"
            commands.append("\(verb) \(String(format: "%.2f", points[0].x)) \(String(format: "%.2f", points[0].y))")
        }
    }
    func rects(_ parts: [CGRect]) -> String {
        parts
            .map { "M\(Int($0.minX)) \(Int($0.minY))h\(Int($0.width))v\(Int($0.height))h-\(Int($0.width))z" }
            .joined(separator: " ")
    }
    let clearance = rects(Mark.letter.map { $0.insetBy(dx: -Mark.clearance, dy: -Mark.clearance) })
    let letter = rects(Mark.letter)
    let field = rects(Mark.fieldCells)

    return """
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024" role="img" aria-label="Searoom mark: a geometric capital S crossing a dithered waterline">
      <title>Searoom mark</title>
      <defs>
        <clipPath id="body">
          <path d="\(commands.joined(separator: " ")) Z"/>
        </clipPath>
      </defs>
      <g clip-path="url(#body)">
        <rect x="\(Int(Mark.body.minX))" y="\(Int(Mark.body.minY))" width="\(Int(Mark.body.width))" height="\(Int(Mark.body.height))" fill="\(Mark.paper)"/>
        <path d="\(field)" fill="\(Mark.ink)"/>
        <rect x="\(Int(Mark.rule.minX))" y="\(Int(Mark.rule.minY))" width="\(Int(Mark.rule.width))" height="\(Int(Mark.rule.height))" fill="\(Mark.ink)"/>
        <path d="\(clearance)" fill="\(Mark.paper)"/>
        <path d="\(letter)" fill="\(Mark.ink)"/>
      </g>
    </svg>

    """
}

func png(from master: NSBitmapImageRep, size: Int) -> Data? {
    guard size != Int(Mark.canvas) else { return master.representation(using: .png, properties: [:]) }
    guard let scaled = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: scaled)
    NSGraphicsContext.current?.imageInterpolation = .high
    master.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return scaled.representation(using: .png, properties: [:])
}

func appendBigEndian(_ value: UInt32, to data: inout Data) {
    var value = value.bigEndian
    withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
}

/// Builds the standard PNG-backed ICNS container directly. This avoids relying on `iconutil`,
/// whose iconset validation has varied between Command Line Tools releases.
func icns(from representations: [String: Data]) -> Data {
    let chunks = [
        ("ic12", "icon_32x32@2x.png"),
        ("ic07", "icon_128x128.png"),
        ("ic13", "icon_128x128@2x.png"),
        ("ic08", "icon_256x256.png"),
        ("ic04", "icon_16x16.png"),
        ("ic14", "icon_256x256@2x.png"),
        ("ic09", "icon_512x512.png"),
        ("ic05", "icon_32x32.png"),
        ("ic10", "icon_512x512@2x.png"),
        ("ic11", "icon_16x16@2x.png")
    ]

    var payload = Data()
    for (type, name) in chunks {
        guard let typeData = type.data(using: .ascii), let imageData = representations[name] else {
            preconditionFailure("Missing ICNS representation: \(name)")
        }
        payload.append(typeData)
        appendBigEndian(UInt32(imageData.count + 8), to: &payload)
        payload.append(imageData)
    }

    var result = Data("icns".utf8)
    appendBigEndian(UInt32(payload.count + 8), to: &result)
    result.append(payload)
    return result
}

// MARK: - Output

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Brand"
let output = URL(fileURLWithPath: outputDirectory, isDirectory: true)
let stagingDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("Searoom-\(UUID().uuidString).brand-stage", isDirectory: true)

guard let master = renderMaster(), let masterData = master.representation(using: .png, properties: [:]) else {
    fputs("Failed to render the mark\n", stderr)
    exit(EXIT_FAILURE)
}

do {
    try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: stagingDirectory) }

    try masterData.write(
        to: stagingDirectory.appendingPathComponent("AppIcon-1024.png"),
        options: .atomic
    )
    try svg().write(
        to: stagingDirectory.appendingPathComponent("searoom-mark.svg"),
        atomically: true,
        encoding: .utf8
    )

    var representations: [String: Data] = [:]

    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let suffix = scale == 1 ? "" : "@2x"
            let name = "icon_\(base)x\(base)\(suffix).png"
            guard let data = png(from: master, size: base * scale) else {
                fputs("Failed to scale the mark to \(base * scale)\n", stderr)
                exit(EXIT_FAILURE)
            }
            representations[name] = data
        }
    }

    try icns(from: representations).write(
        to: stagingDirectory.appendingPathComponent("AppIcon.icns"),
        options: .atomic
    )

    // Publish only after every representation succeeds, keeping the three shipped assets in sync.
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for name in ["AppIcon-1024.png", "searoom-mark.svg", "AppIcon.icns"] {
        let data = try Data(contentsOf: stagingDirectory.appendingPathComponent(name))
        try data.write(to: output.appendingPathComponent(name), options: .atomic)
    }
} catch {
    fputs("Failed to write brand assets: \(error)\n", stderr)
    exit(EXIT_FAILURE)
}

print("Wrote AppIcon-1024.png, searoom-mark.svg, and AppIcon.icns to \(output.path)")
