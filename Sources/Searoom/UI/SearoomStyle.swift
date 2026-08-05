import AppKit
import CoreText

@MainActor
enum SearoomFont {
    private(set) static var isDepartureMonoAvailable = false
    private static var metricCache: [CGFloat: NSFont] = [:]

    static func registerBundledFont() {
        let candidates = [
            ("DepartureMono-Regular", "otf"),
            ("DepartureMono-Regular", "ttf"),
            ("DepartureMono", "otf"),
            ("DepartureMono", "ttf")
        ]
        for candidate in candidates {
            for subdirectory in ["Fonts", nil] as [String?] {
                guard let url = Bundle.module.url(
                    forResource: candidate.0,
                    withExtension: candidate.1,
                    subdirectory: subdirectory
                ) else { continue }
                var error: Unmanaged<CFError>?
                if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                    isDepartureMonoAvailable = true
                    return
                }
            }
        }
        isDepartureMonoAvailable = NSFont(name: "DepartureMono-Regular", size: 12) != nil
            || NSFont(name: "Departure Mono", size: 12) != nil
    }

    static func metric(_ size: CGFloat) -> NSFont {
        if let cached = metricCache[size] { return cached }
        let font = NSFont(name: "DepartureMono-Regular", size: size)
            ?? NSFont(name: "Departure Mono", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        metricCache[size] = font
        return font
    }

    static func system(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }
}

@MainActor
struct SearoomTheme {
    let paper: NSColor
    let ink: NSColor
    let subdued: NSColor
    let nominal: NSColor
    let elevated: NSColor
    let constrained: NSColor
    let critical: NSColor
    let cool: NSColor

    init(appearance: NSAppearance?) {
        let dark = appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if dark {
            paper = NSColor(calibratedRed: 0.067, green: 0.071, blue: 0.063, alpha: 1)
            ink = NSColor(calibratedRed: 0.914, green: 0.906, blue: 0.867, alpha: 1)
            subdued = NSColor(calibratedWhite: 0.66, alpha: 1)
            nominal = NSColor(calibratedRed: 0.525, green: 0.851, blue: 0.561, alpha: 1)
            elevated = NSColor(calibratedRed: 1, green: 0.784, blue: 0.341, alpha: 1)
            constrained = NSColor(calibratedRed: 1, green: 0.53, blue: 0.27, alpha: 1)
            critical = NSColor(calibratedRed: 1, green: 0.42, blue: 0.38, alpha: 1)
            cool = NSColor(calibratedRed: 0.451, green: 0.718, blue: 0.827, alpha: 1)
        } else {
            paper = NSColor(calibratedRed: 0.933, green: 0.918, blue: 0.875, alpha: 1)
            ink = NSColor(calibratedRed: 0.082, green: 0.086, blue: 0.075, alpha: 1)
            subdued = NSColor(calibratedWhite: 0.35, alpha: 1)
            nominal = NSColor(calibratedRed: 0.27, green: 0.53, blue: 0.31, alpha: 1)
            elevated = NSColor(calibratedRed: 0.68, green: 0.42, blue: 0.04, alpha: 1)
            constrained = NSColor(calibratedRed: 0.77, green: 0.27, blue: 0.08, alpha: 1)
            critical = NSColor(calibratedRed: 0.72, green: 0.18, blue: 0.15, alpha: 1)
            cool = NSColor(calibratedRed: 0.20, green: 0.42, blue: 0.54, alpha: 1)
        }
    }

    func color(for pressure: PressureLevel) -> NSColor {
        switch pressure {
        case .nominal: nominal
        case .elevated: elevated
        case .constrained: constrained
        case .critical: critical
        case .unavailable: subdued
        }
    }
}

@MainActor
enum DitherPattern {
    private static let matrix: [[Int]] = [
        [0, 8, 2, 10],
        [12, 4, 14, 6],
        [3, 11, 1, 9],
        [15, 7, 13, 5]
    ]
    private static var cache: [CacheKey: NSColor] = [:]

    static func color(foreground: NSColor, density: Double) -> NSColor {
        let clamped = min(1, max(0.04, density))
        let rgb = foreground.usingColorSpace(.deviceRGB) ?? foreground
        let threshold = Int((clamped * 16).rounded(.up))
        let key = CacheKey(
            red: Int((rgb.redComponent * 255).rounded()),
            green: Int((rgb.greenComponent * 255).rounded()),
            blue: Int((rgb.blueComponent * 255).rounded()),
            alpha: Int((rgb.alphaComponent * 255).rounded()),
            threshold: threshold
        )
        if let cached = cache[key] { return cached }

        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.clear.setFill()
            rect.fill()
            rgb.setFill()
            for row in 0..<4 {
                for column in 0..<4 where matrix[row][column] < threshold {
                    NSRect(
                        x: CGFloat(column * 2),
                        y: CGFloat(row * 2),
                        width: 1.25,
                        height: 1.25
                    ).fill()
                }
            }
            return true
        }
        let pattern = NSColor(patternImage: image)
        cache[key] = pattern
        return pattern
    }

    static func fill(_ path: NSBezierPath, color: NSColor, density: Double) {
        self.color(foreground: color, density: density).setFill()
        path.fill()
    }

    private struct CacheKey: Hashable {
        let red: Int
        let green: Int
        let blue: Int
        let alpha: Int
        let threshold: Int
    }
}

@MainActor
enum SearoomIcon {
    private static var cache: [PressureLevel: NSImage] = [:]

    static func image(for level: PressureLevel) -> NSImage {
        if let cached = cache[level] { return cached }
        let density: Double = switch level {
        case .unavailable, .nominal: 0.25
        case .elevated: 0.45
        case .constrained: 0.68
        case .critical: 0.9
        }

        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let ink = NSColor.black
            ink.setFill()
            // Proportions follow Brand/searoom-mark.svg: a block S crosses the waterline,
            // while its lower counter carries the pressure-dependent dither field.
            let chamber = NSBezierPath(rect: NSRect(x: 5, y: 4, width: 6, height: 3))
            DitherPattern.fill(chamber, color: ink, density: density)
            NSRect(x: 4, y: 14, width: 10, height: 2).fill()
            NSRect(x: 4, y: 9, width: 2, height: 5).fill()
            NSRect(x: 4, y: 8, width: 10, height: 2).fill()
            NSRect(x: 12, y: 3, width: 2, height: 5).fill()
            NSRect(x: 4, y: 2, width: 10, height: 2).fill()
            if level == .critical {
                NSRect(x: 8, y: 11, width: 2, height: 2).fill()
            }
            return true
        }
        image.isTemplate = true
        cache[level] = image
        return image
    }
}

@MainActor
enum SearoomStatusDot {
    private static var cache: [String: NSImage] = [:]

    static func image(for level: PressureLevel, appearance: NSAppearance?) -> NSImage {
        let isDark = appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let key = "\(level.rawValue)-\(isDark ? "dark" : "light")"
        if let cached = cache[key] { return cached }

        let color = SearoomTheme(appearance: appearance).color(for: level)
        let image = NSImage(size: NSSize(width: 7, height: 7), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        cache[key] = image
        return image
    }
}
