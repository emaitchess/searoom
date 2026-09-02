import Foundation

enum MetricByteUnit: CaseIterable, Equatable, Sendable {
    case gigabytes
    case megabytes

    var label: String {
        switch self {
        case .gigabytes: "GB"
        case .megabytes: "MB"
        }
    }
}

enum MetricTemperatureUnit: CaseIterable, Equatable, Sendable {
    case celsius
    case fahrenheit

    var label: String {
        switch self {
        case .celsius: "degrees Celsius"
        case .fahrenheit: "degrees Fahrenheit"
        }
    }
}

enum MetricRateUnit: CaseIterable, Equatable, Sendable {
    case adaptive
    case bytes
    case kilobytes
    case megabytes
    case gigabytes

    var label: String {
        switch self {
        case .adaptive: "adaptive"
        case .bytes: "bytes per second"
        case .kilobytes: "kilobytes per second"
        case .megabytes: "megabytes per second"
        case .gigabytes: "gigabytes per second"
        }
    }
}

enum MetricFormat {
    static func bytes(_ value: UInt64) -> String {
        let gib = Double(value) / 1_073_741_824
        if gib >= 1 { return String(format: gib >= 10 ? "%.1f GB" : "%.2f GB", gib) }
        let mib = Double(value) / 1_048_576
        if mib >= 1 { return String(format: "%.1f MB", mib) }
        let kib = Double(value) / 1_024
        return String(format: "%.0f KB", kib)
    }

    static func compactBytes(_ value: UInt64) -> String {
        let gib = Double(value) / 1_073_741_824
        if gib >= 1 { return String(format: gib >= 10 ? "%.0fG" : "%.1fG", gib) }
        let mib = Double(value) / 1_048_576
        return String(format: "%.0fM", mib)
    }

    static func bytes(_ value: UInt64, unit: MetricByteUnit) -> String {
        switch unit {
        case .gigabytes:
            let gib = Double(value) / 1_073_741_824
            return String(format: gib >= 10 ? "%.1f GB" : "%.2f GB", gib)
        case .megabytes:
            return String(format: "%.0f MB", Double(value) / 1_048_576)
        }
    }

    static func compactBytes(_ value: UInt64, unit: MetricByteUnit) -> String {
        compactByteNumber(value, unit: unit) + unit.label
    }

    static func bytePair(_ first: UInt64, _ second: UInt64, unit: MetricByteUnit) -> String {
        "\(compactByteNumber(first, unit: unit))/\(compactByteNumber(second, unit: unit))\(unit.label)"
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        let value = max(0, bytesPerSecond)
        if value >= 1_000_000_000 { return String(format: "%.1f GB/s", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1f MB/s", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.0f KB/s", value / 1_000) }
        return String(format: "%.0f B/s", value)
    }

    static func rate(_ bytesPerSecond: Double, unit: MetricRateUnit) -> String {
        let value = bytesPerSecond.isFinite ? max(0, bytesPerSecond) : 0
        switch unit {
        case .adaptive:
            return rate(value)
        case .bytes:
            return String(format: "%.0f B/s", value)
        case .kilobytes:
            return String(format: "%.1f KB/s", value / 1_000)
        case .megabytes:
            return String(format: "%.1f MB/s", value / 1_000_000)
        case .gigabytes:
            return String(format: "%.2f GB/s", value / 1_000_000_000)
        }
    }

    static func compactRate(_ bytesPerSecond: Double) -> String {
        let value = max(0, bytesPerSecond)
        if value >= 1_000_000_000 { return String(format: "%.1fG", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.0fK", value / 1_000) }
        return String(format: "%.0fB", value)
    }

    static func percent(_ fraction: Double) -> String {
        String(format: "%.0f%%", max(0, min(1, fraction)) * 100)
    }

    static func unboundedPercent(_ fraction: Double) -> String {
        String(format: "%.0f%%", max(0, fraction) * 100)
    }

    static func fixedField(_ value: String, columns: Int) -> String {
        guard value.count < columns else { return value }
        return String(repeating: " ", count: columns - value.count) + value
    }

    static func fixedLabel(_ value: String, columns: Int) -> String {
        guard value.count < columns else { return value }
        return value + String(repeating: " ", count: columns - value.count)
    }

    static func temperature(_ celsius: Double?) -> String {
        guard let celsius else { return "N/A" }
        return String(format: "%.0f°C", celsius)
    }

    static func temperature(_ celsius: Double?, unit: MetricTemperatureUnit) -> String {
        guard let celsius else { return "N/A" }
        switch unit {
        case .celsius:
            return String(format: "%.0f°C", celsius)
        case .fahrenheit:
            return String(format: "%.0f°F", celsius * 9 / 5 + 32)
        }
    }

    static func fanActivity(_ fans: [FanSample]) -> String {
        guard !fans.isEmpty else { return "N/A" }
        if fans.count == 1 { return "\(Int(fans[0].rpm)) RPM" }
        return fans.enumerated().map { index, fan in
            "F\(index + 1) \(Int(fan.rpm))"
        }.joined(separator: " · ")
    }

    static func uptime(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return String(format: "%02dD %02dH", days, hours) }
        return String(format: "%02dH %02dM", hours, minutes)
    }

    static func compactDuration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        let minutes = seconds / 60
        let hours = minutes / 60
        let days = hours / 24
        if days > 0 { return String(format: "%02dD %02dH", days, hours % 24) }
        if hours > 0 { return String(format: "%02dH %02dM", hours, minutes % 60) }
        return String(format: "%02dM", minutes)
    }

    private static func compactByteNumber(_ value: UInt64, unit: MetricByteUnit) -> String {
        switch unit {
        case .gigabytes:
            let gib = Double(value) / 1_073_741_824
            return String(format: gib >= 10 ? "%.0f" : "%.1f", gib)
        case .megabytes:
            return String(format: "%.0f", Double(value) / 1_048_576)
        }
    }
}
