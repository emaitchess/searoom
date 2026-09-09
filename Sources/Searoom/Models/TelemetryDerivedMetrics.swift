import Foundation

/// App- and CLI-shared pure derivations over `SystemSample` and history.
/// Everything here is UI-independent so the dashboard and the CLI cannot
/// drift. Formulas that already existed as shared pure helpers
/// (`SustainedPressure`, `GPUCollector.workingSetRatio`) stay where they are;
/// this type holds the rest.
enum TelemetryDerivedMetrics {
    struct LimitingResource: Equatable, Sendable {
        let resource: String
        let level: PressureLevel
        let valueFraction: Double?
    }

    /// The resources currently at the highest pressure level, ties retained.
    /// Availability gates each candidate: an unavailable sensor is never
    /// limiting.
    static func limitingResources(in sample: SystemSample) -> [LimitingResource] {
        var candidates: [LimitingResource] = []
        if sample.availability.cpuUsageLoad == .available {
            candidates.append(
                LimitingResource(resource: "cpu", level: sample.cpuPressureLevel, valueFraction: sample.cpuPressure)
            )
        }
        if sample.availability.vmStatistics == .available {
            candidates.append(
                LimitingResource(
                    resource: "memory",
                    level: sample.memoryPressureLevel,
                    valueFraction: sample.memoryPressure
                )
            )
        }
        if sample.thermalPressureLevel != .unavailable {
            candidates.append(
                LimitingResource(resource: "thermal", level: sample.thermalPressureLevel, valueFraction: nil)
            )
        }
        if sample.gpuPressureLevel != .unavailable {
            candidates.append(
                LimitingResource(resource: "gpu", level: sample.gpuPressureLevel, valueFraction: sample.gpuPressure)
            )
        }
        guard let strongest = candidates.map(\.level).max(), strongest != .unavailable else { return [] }
        // At nominal nothing is limiting; the list is only meaningful from
        // elevated upward. Ties at the strongest level are all retained.
        guard strongest != .nominal else { return [] }
        return candidates.filter { $0.level == strongest }
    }

    static func memoryUsedFraction(_ sample: SystemSample) -> Double? {
        guard sample.memoryTotal > 0 else { return nil }
        return min(1, Double(sample.memoryUsed) / Double(sample.memoryTotal))
    }

    static func memoryCompressedFraction(_ sample: SystemSample) -> Double? {
        guard sample.memoryTotal > 0 else { return nil }
        return min(1, Double(sample.compressedMemoryBytes) / Double(sample.memoryTotal))
    }

    /// Recommended working set minus in-use GPU memory; nil unless both
    /// readings exist and are ordered.
    static func gpuWorkingSetHeadroomBytes(_ sample: SystemSample) -> UInt64? {
        guard let used = sample.gpuMemoryUsedBytes,
              let recommended = sample.gpuMemoryRecommendedBytes,
              recommended >= used else { return nil }
        return recommended - used
    }

    /// The app-equivalent power state label: source plus Low Power Mode.
    static func powerStateLabel(_ sample: SystemSample) -> String {
        var label: String
        switch sample.isOnExternalPower {
        case .some(true): label = "AC POWER"
        case .some(false): label = "BATTERY"
        case .none: label = "POWER SOURCE UNKNOWN"
        }
        if sample.isLowPowerModeEnabled { label += " (LOW POWER MODE)" }
        return label
    }

    /// Swap and compression I/O are activity signals, not pressure signals:
    /// any measurable byte flow counts as active.
    static func swapActivityState(_ sample: SystemSample) -> String {
        if sample.availability.swapIO == .unavailable
            && sample.availability.compressionIO == .unavailable {
            return "unavailable"
        }
        let rates = [
            sample.swapInPerSecond,
            sample.swapOutPerSecond,
            sample.compressionBytesPerSecond,
            sample.decompressionBytesPerSecond
        ]
        return rates.contains { $0 >= 1 } ? "active" : "idle"
    }

    /// Fan names are positional labels synthesized by the collector, not SMC
    /// names; state derives from measured RPM only.
    static func fanState(_ sample: SystemSample) -> String {
        if sample.fans.isEmpty { return "unavailable" }
        return sample.fans.contains { $0.rpm > 0 } ? "spinning" : "idle"
    }

    /// Searoom's own cost as a pressure-style label. The raw observer CPU
    /// reading may exceed 1.0 across cores; the level clamps it because the
    /// label describes saturation, not utilization.
    static func observerState(_ sample: SystemSample) -> String {
        switch sample.availability.processCPU {
        case .unavailable: return "unavailable"
        case .warmingUp: return "warmingUp"
        case .available, .legacyUnknown:
            return PressureLevel.from(utilization: min(1, max(0, sample.processCPUUsage))).outputLabel
        }
    }

    /// The strongest overall pressure level anywhere in the retained samples,
    /// with the most recent timestamp that reached it. Computed before any
    /// display filtering.
    static func recentPeakPressure<Samples: BidirectionalCollection>(
        in samples: Samples
    ) -> (level: PressureLevel, timestamp: Date)? where Samples.Element == SystemSample {
        var peak: PressureLevel?
        var timestamp: Date?
        for sample in samples {
            let level = sample.overallPressureLevel
            guard level != .unavailable else { continue }
            if let current = peak {
                if level >= current {
                    peak = level
                    timestamp = sample.timestamp
                }
            } else {
                peak = level
                timestamp = sample.timestamp
            }
        }
        guard let peak, let timestamp else { return nil }
        return (peak, timestamp)
    }
}
