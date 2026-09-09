import Foundation

/// The exact `--dump-sample` output shape that shipped before the CLI existed:
/// 41 fields, integer pressure levels, ISO 8601 whole-second timestamps, and
/// no availability metadata. `SystemSample` now carries availability, so this
/// explicit projection — not direct model encoding — preserves the legacy
/// bytes for existing consumers. New automation should use `searoom sample`.
struct LegacyDumpSample: Encodable {
    let timestamp: String
    let cpuUsage: Double
    let cpuPressure: Double
    let cpuPressureLevel: Int
    let loadAverage1m: Double
    let logicalCPUCount: Int
    let memoryTotal: UInt64
    let memoryUsed: UInt64
    let memoryAvailable: UInt64
    let memoryCached: UInt64
    let swapUsed: UInt64
    let swapInPerSecond: Double
    let swapOutPerSecond: Double
    let compressedMemoryBytes: UInt64
    let compressionBytesPerSecond: Double
    let decompressionBytesPerSecond: Double
    let memoryPressure: Double
    let memoryPressureLevel: Int
    let temperatureCelsius: Double?
    let temperatureSource: String
    let thermalPressureLevel: Int
    let gpuUsage: Double?
    let gpuPressure: Double?
    let gpuPressureLevel: Int
    let gpuMemoryUsedBytes: UInt64?
    let gpuMemoryRecommendedBytes: UInt64?
    let gpuMemoryPressure: Double?
    let fans: [Fan]
    let networkDownloadPerSecond: Double
    let networkUploadPerSecond: Double
    let diskReadPerSecond: Double
    let diskWritePerSecond: Double
    let diskCapacityBytes: UInt64?
    let diskAvailableBytes: UInt64?
    let uptime: TimeInterval
    let processCPUUsage: Double
    let processMemoryBytes: UInt64
    let processCount: Int
    let batteryPercent: Double?
    let isOnExternalPower: Bool?
    let isLowPowerModeEnabled: Bool

    struct Fan: Encodable {
        let name: String
        let rpm: Double
    }

    static let fieldCount = 41

    static func make(from sample: SystemSample) -> LegacyDumpSample {
        LegacyDumpSample(
            timestamp: makeISO8601Formatter().string(from: sample.timestamp),
            cpuUsage: sample.cpuUsage,
            cpuPressure: sample.cpuPressure,
            cpuPressureLevel: sample.cpuPressureLevel.rawValue,
            loadAverage1m: sample.loadAverage1m,
            logicalCPUCount: sample.logicalCPUCount,
            memoryTotal: sample.memoryTotal,
            memoryUsed: sample.memoryUsed,
            memoryAvailable: sample.memoryAvailable,
            memoryCached: sample.memoryCached,
            swapUsed: sample.swapUsed,
            swapInPerSecond: sample.swapInPerSecond,
            swapOutPerSecond: sample.swapOutPerSecond,
            compressedMemoryBytes: sample.compressedMemoryBytes,
            compressionBytesPerSecond: sample.compressionBytesPerSecond,
            decompressionBytesPerSecond: sample.decompressionBytesPerSecond,
            memoryPressure: sample.memoryPressure,
            memoryPressureLevel: sample.memoryPressureLevel.rawValue,
            temperatureCelsius: sample.temperatureCelsius,
            temperatureSource: sample.temperatureSource.rawValue,
            thermalPressureLevel: sample.thermalPressureLevel.rawValue,
            gpuUsage: sample.gpuUsage,
            gpuPressure: sample.gpuPressure,
            gpuPressureLevel: sample.gpuPressureLevel.rawValue,
            gpuMemoryUsedBytes: sample.gpuMemoryUsedBytes,
            gpuMemoryRecommendedBytes: sample.gpuMemoryRecommendedBytes,
            gpuMemoryPressure: sample.gpuMemoryPressure,
            fans: sample.fans.map { Fan(name: $0.name, rpm: $0.rpm) },
            networkDownloadPerSecond: sample.networkDownloadPerSecond,
            networkUploadPerSecond: sample.networkUploadPerSecond,
            diskReadPerSecond: sample.diskReadPerSecond,
            diskWritePerSecond: sample.diskWritePerSecond,
            diskCapacityBytes: sample.diskCapacityBytes,
            diskAvailableBytes: sample.diskAvailableBytes,
            uptime: sample.uptime,
            processCPUUsage: sample.processCPUUsage,
            processMemoryBytes: sample.processMemoryBytes,
            processCount: sample.processCount,
            batteryPercent: sample.batteryPercent,
            isOnExternalPower: sample.isOnExternalPower,
            isLowPowerModeEnabled: sample.isLowPowerModeEnabled
        )
    }

    /// The legacy encoder used `.iso8601`, which is whole seconds in UTC.
    private static func makeISO8601Formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    /// Synthesized Encodable would omit nil optionals; the legacy shape is
    /// exactly 41 keys with explicit nulls, every time.
    private enum CodingKeys: String, CodingKey {
        case timestamp, cpuUsage, cpuPressure, cpuPressureLevel, loadAverage1m
        case logicalCPUCount, memoryTotal, memoryUsed, memoryAvailable, memoryCached
        case swapUsed, swapInPerSecond, swapOutPerSecond, compressedMemoryBytes
        case compressionBytesPerSecond, decompressionBytesPerSecond, memoryPressure
        case memoryPressureLevel, temperatureCelsius, temperatureSource
        case thermalPressureLevel, gpuUsage, gpuPressure, gpuPressureLevel
        case gpuMemoryUsedBytes, gpuMemoryRecommendedBytes, gpuMemoryPressure, fans
        case networkDownloadPerSecond, networkUploadPerSecond, diskReadPerSecond
        case diskWritePerSecond, diskCapacityBytes, diskAvailableBytes, uptime
        case processCPUUsage, processMemoryBytes, processCount, batteryPercent
        case isOnExternalPower, isLowPowerModeEnabled
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(cpuUsage, forKey: .cpuUsage)
        try container.encode(cpuPressure, forKey: .cpuPressure)
        try container.encode(cpuPressureLevel, forKey: .cpuPressureLevel)
        try container.encode(loadAverage1m, forKey: .loadAverage1m)
        try container.encode(logicalCPUCount, forKey: .logicalCPUCount)
        try container.encode(memoryTotal, forKey: .memoryTotal)
        try container.encode(memoryUsed, forKey: .memoryUsed)
        try container.encode(memoryAvailable, forKey: .memoryAvailable)
        try container.encode(memoryCached, forKey: .memoryCached)
        try container.encode(swapUsed, forKey: .swapUsed)
        try container.encode(swapInPerSecond, forKey: .swapInPerSecond)
        try container.encode(swapOutPerSecond, forKey: .swapOutPerSecond)
        try container.encode(compressedMemoryBytes, forKey: .compressedMemoryBytes)
        try container.encode(compressionBytesPerSecond, forKey: .compressionBytesPerSecond)
        try container.encode(decompressionBytesPerSecond, forKey: .decompressionBytesPerSecond)
        try container.encode(memoryPressure, forKey: .memoryPressure)
        try container.encode(memoryPressureLevel, forKey: .memoryPressureLevel)
        if let temperatureCelsius {
            try container.encode(temperatureCelsius, forKey: .temperatureCelsius)
        } else {
            try container.encodeNil(forKey: .temperatureCelsius)
        }
        try container.encode(temperatureSource, forKey: .temperatureSource)
        try container.encode(thermalPressureLevel, forKey: .thermalPressureLevel)
        if let gpuUsage {
            try container.encode(gpuUsage, forKey: .gpuUsage)
        } else {
            try container.encodeNil(forKey: .gpuUsage)
        }
        if let gpuPressure {
            try container.encode(gpuPressure, forKey: .gpuPressure)
        } else {
            try container.encodeNil(forKey: .gpuPressure)
        }
        try container.encode(gpuPressureLevel, forKey: .gpuPressureLevel)
        if let gpuMemoryUsedBytes {
            try container.encode(gpuMemoryUsedBytes, forKey: .gpuMemoryUsedBytes)
        } else {
            try container.encodeNil(forKey: .gpuMemoryUsedBytes)
        }
        if let gpuMemoryRecommendedBytes {
            try container.encode(gpuMemoryRecommendedBytes, forKey: .gpuMemoryRecommendedBytes)
        } else {
            try container.encodeNil(forKey: .gpuMemoryRecommendedBytes)
        }
        if let gpuMemoryPressure {
            try container.encode(gpuMemoryPressure, forKey: .gpuMemoryPressure)
        } else {
            try container.encodeNil(forKey: .gpuMemoryPressure)
        }
        try container.encode(fans, forKey: .fans)
        try container.encode(networkDownloadPerSecond, forKey: .networkDownloadPerSecond)
        try container.encode(networkUploadPerSecond, forKey: .networkUploadPerSecond)
        try container.encode(diskReadPerSecond, forKey: .diskReadPerSecond)
        try container.encode(diskWritePerSecond, forKey: .diskWritePerSecond)
        if let diskCapacityBytes {
            try container.encode(diskCapacityBytes, forKey: .diskCapacityBytes)
        } else {
            try container.encodeNil(forKey: .diskCapacityBytes)
        }
        if let diskAvailableBytes {
            try container.encode(diskAvailableBytes, forKey: .diskAvailableBytes)
        } else {
            try container.encodeNil(forKey: .diskAvailableBytes)
        }
        try container.encode(uptime, forKey: .uptime)
        try container.encode(processCPUUsage, forKey: .processCPUUsage)
        try container.encode(processMemoryBytes, forKey: .processMemoryBytes)
        try container.encode(processCount, forKey: .processCount)
        if let batteryPercent {
            try container.encode(batteryPercent, forKey: .batteryPercent)
        } else {
            try container.encodeNil(forKey: .batteryPercent)
        }
        if let isOnExternalPower {
            try container.encode(isOnExternalPower, forKey: .isOnExternalPower)
        } else {
            try container.encodeNil(forKey: .isOnExternalPower)
        }
        try container.encode(isLowPowerModeEnabled, forKey: .isLowPowerModeEnabled)
    }

    static func makeJSON(from sample: SystemSample, pretty: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(LegacyDumpSample.make(from: sample))
    }
}
