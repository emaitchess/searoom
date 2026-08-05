import Foundation

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

    static func rate(_ bytesPerSecond: Double) -> String {
        let value = max(0, bytesPerSecond)
        if value >= 1_000_000_000 { return String(format: "%.1f GB/s", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1f MB/s", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.0f KB/s", value / 1_000) }
        return String(format: "%.0f B/s", value)
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
}
