import AppKit

enum MenuBarTone: Equatable {
    case pressure(PressureLevel)
    case activity(Bool)
    case neutral
}

struct MenuBarComponent: Equatable {
    /// A second reading stacked beneath the first, for metrics that are a pair
    /// rather than a label and a number. Network up and down is the case: both
    /// lines are readings, each labelled by its own arrow, so neither should be
    /// dimmed the way a label is.
    struct Pair: Equatable {
        let label: String
        let value: String
        let tone: MenuBarTone
    }

    /// Carries its own trailing separator, so a component with no gap between
    /// label and value (the network arrows) renders exactly as it always has.
    let label: String
    /// Already padded to its fixed column, which is what keeps the item from
    /// changing width as the reading changes.
    let value: String
    let tone: MenuBarTone
    var second: Pair?

    var text: String {
        guard let second else { return label + value }
        return "\(label)\(value) \(second.label)\(second.value)"
    }

    /// The label without its padding, for the stacked layout where the space
    /// between label and value is vertical rather than horizontal.
    var trimmedLabel: String { label.trimmingCharacters(in: .whitespaces) }

    /// The reading without its padding. The padded `value` still sets the
    /// column width, so trimming here cannot make anything move.
    var trimmedValue: String { value.trimmingCharacters(in: .whitespaces) }
}

/// Draws the status item as stacked label-over-value columns.
///
/// An inline row spends its width badly: `CPU␣␣␣4%` uses eight character
/// columns to show a two-character reading, because the padding that stops the
/// item twitching sits between the label and its value. Stacking moves that
/// separation into the vertical axis, which roughly halves the width and binds
/// each label to its own value, so the separator between groups stops carrying
/// meaning it was never wide enough to carry.
///
/// The menu bar is only about 22pt tall, so both lines are small. `inline`
/// remains available for anyone who would rather have one larger line.
@MainActor
enum MenuBarRenderer {
    static let labelFontSize: CGFloat = 7.5
    static let valueFontSize: CGFloat = 9.5
    /// Between one column's value and the next column's label. Wider than any
    /// gap inside a column, so the grouping reads correctly without needing a
    /// separator glyph at all.
    static let columnGap: CGFloat = 9
    /// Between the cap heights of the two lines. Layout is packed by baseline
    /// rather than by line box: Departure Mono's natural line height is 13pt at
    /// 9.5pt, so two of them want 26pt inside a bar that is 22pt tall, and even
    /// a small label over a value wants 23pt. Packing by cap height fits both
    /// comfortably, and the readings carry no descenders to collide.
    static let lineGap: CGFloat = 2.5
    static let dotGap: CGFloat = 5
    static let edgeInset: CGFloat = 4

    /// The width of one column: the wider of its label and its *padded* value.
    ///
    /// Measuring the padded value is the whole trick. The padding already
    /// reserves the widest reading the field can hold, so the column cannot
    /// change width as the reading changes, and neither can anything after it.
    static func columnWidth(_ component: MenuBarComponent) -> CGFloat {
        let valueFont = SearoomFont.metric(valueFontSize)
        if let second = component.second {
            // Both lines are readings, and both are measured padded, so the
            // pair is as stable as any single reading.
            return max(
                width(component.label + component.value, font: valueFont),
                width(second.label + second.value, font: valueFont)
            )
        }
        return max(
            width(component.trimmedLabel, font: SearoomFont.metric(labelFontSize)),
            width(component.value, font: valueFont)
        )
    }

    static func imageWidth(for components: [MenuBarComponent], includesDot: Bool) -> CGFloat {
        guard !components.isEmpty else { return 0 }
        let columns = components.map(columnWidth).reduce(0, +)
        let gaps = columnGap * CGFloat(components.count - 1)
        let dot = includesDot ? dotWidth + dotGap : 0
        return edgeInset * 2 + dot + columns + gaps
    }

    static func image(
        components: [MenuBarComponent],
        level: PressureLevel,
        appearance: NSAppearance?
    ) -> NSImage {
        let theme = SearoomTheme(appearance: appearance)
        let labelFont = SearoomFont.metric(labelFontSize)
        let valueFont = SearoomFont.metric(valueFontSize)
        let height = NSStatusBar.system.thickness
        let size = NSSize(
            width: max(1, imageWidth(for: components, includesDot: true)),
            height: height
        )
        let dot = SearoomStatusDot.image(for: level, appearance: appearance)

        let image = NSImage(size: size, flipped: true) { _ in
            dot.draw(
                in: NSRect(
                    x: edgeInset,
                    y: (height - dotWidth).rounded(.down) / 2,
                    width: dotWidth,
                    height: dotWidth
                ),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )

            var x = edgeInset + dotWidth + dotGap
            for component in components {
                let column = columnWidth(component)
                let lines: [(text: NSAttributedString, font: NSFont)]
                if let second = component.second {
                    // A pair is two readings, so neither line is dimmed.
                    lines = [
                        (NSAttributedString(
                            string: component.label + component.trimmedValue,
                            attributes: [
                                .font: valueFont,
                                .foregroundColor: color(for: component.tone, theme: theme)
                            ]
                        ), valueFont),
                        (NSAttributedString(
                            string: second.label
                                + second.value.trimmingCharacters(in: .whitespaces),
                            attributes: [
                                .font: valueFont,
                                .foregroundColor: color(for: second.tone, theme: theme)
                            ]
                        ), valueFont)
                    ]
                } else {
                    lines = [
                        (NSAttributedString(
                            string: component.trimmedLabel,
                            attributes: [.font: labelFont, .foregroundColor: theme.subdued]
                        ), labelFont),
                        (NSAttributedString(
                            string: component.trimmedValue,
                            attributes: [
                                .font: valueFont,
                                .foregroundColor: color(for: component.tone, theme: theme)
                            ]
                        ), valueFont)
                    ]
                }
                // Both lines lead from the same edge, matching the dashboard's
                // rule that values align leading. Centring would look tidier
                // and would move the reading every time a digit appeared.
                let caps = lines.map(\.font.capHeight)
                let block = caps.reduce(0, +) + lineGap * CGFloat(lines.count - 1)
                var baseline = (height - block) / 2 + caps[0]
                for (index, line) in lines.enumerated() {
                    // draw(at:) places the line box, whose baseline sits one
                    // ascender below it.
                    line.text.draw(at: NSPoint(x: x, y: baseline - line.font.ascender))
                    if index + 1 < caps.count { baseline += lineGap + caps[index + 1] }
                }
                x += column + columnGap
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    static func color(for tone: MenuBarTone, theme: SearoomTheme) -> NSColor {
        switch tone {
        case .pressure(let level): theme.color(for: level)
        case .activity(true): theme.cool
        case .activity(false): theme.subdued
        case .neutral: .labelColor
        }
    }

    private static let dotWidth: CGFloat = 7

    private static func width(_ text: String, font: NSFont) -> CGFloat {
        NSAttributedString(string: text, attributes: [.font: font]).size().width
    }
}
