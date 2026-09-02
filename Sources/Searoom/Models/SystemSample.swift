import Foundation

enum PressureLevel: Int, Codable, CaseIterable, Comparable, Sendable {
    case nominal = 0
    case elevated = 1
    case constrained = 2
    case critical = 3
    case unavailable = -1

    static func < (lhs: PressureLevel, rhs: PressureLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .nominal: "NOMINAL"
        case .elevated: "ELEVATED"
        case .constrained: "CONSTRAINED"
        case .critical: "CRITICAL"
        case .unavailable: "UNAVAILABLE"
        }
    }

    var systemLabel: String {
        switch self {
        case .nominal: "ALL CLEAR"
        case .elevated: "BUSY"
        case .constrained: "CONSTRAINED"
        case .critical: "CRITICAL"
        case .unavailable: "CHECKING"
        }
    }

    var compactLabel: String {
        switch self {
        case .nominal: "OK"
        case .elevated: "BUSY"
        case .constrained: "TIGHT"
        case .critical: "CRIT"
        case .unavailable: "N/A"
        }
    }

    static func from(utilization: Double) -> PressureLevel {
        switch utilization {
        case ..<0.70: .nominal
        case ..<0.85: .elevated
        case ..<0.95: .constrained
        default: .critical
        }
    }

}

struct FanSample: Codable, Equatable, Sendable {
    let name: String
    let rpm: Double
}

enum TemperatureSource: String, Codable, Equatable, Sendable {
    case cpuPackage
    case battery
    case unavailable

    var label: String {
        switch self {
        case .cpuPackage: "CPU PACKAGE"
        case .battery: "BATTERY SENSOR"
        case .unavailable: "SENSOR UNAVAILABLE"
        }
    }

    var compactLabel: String {
        switch self {
        case .cpuPackage: "CPU"
        case .battery: "BAT"
        case .unavailable: "TEMP"
        }
    }
}

struct SystemSample: Codable, Equatable, Sendable {
    let timestamp: Date

    let cpuUsage: Double
    let cpuPressure: Double
    let cpuPressureLevel: PressureLevel
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
    let memoryPressureLevel: PressureLevel

    let temperatureCelsius: Double?
    let temperatureSource: TemperatureSource
    let thermalPressureLevel: PressureLevel
    let gpuUsage: Double?
    let gpuPressure: Double?
    let gpuPressureLevel: PressureLevel
    let gpuMemoryUsedBytes: UInt64?
    let gpuMemoryRecommendedBytes: UInt64?
    let gpuMemoryPressure: Double?
    let fans: [FanSample]

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

    var overallPressureLevel: PressureLevel {
        max(
            max(cpuPressureLevel, memoryPressureLevel),
            max(thermalPressureLevel, gpuPressureLevel)
        )
    }
}

extension SystemSample {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try values.decode(Date.self, forKey: .timestamp)
        cpuUsage = try values.decode(Double.self, forKey: .cpuUsage)
        cpuPressure = try values.decode(Double.self, forKey: .cpuPressure)
        cpuPressureLevel = try values.decode(PressureLevel.self, forKey: .cpuPressureLevel)
        loadAverage1m = try values.decode(Double.self, forKey: .loadAverage1m)
        logicalCPUCount = try values.decode(Int.self, forKey: .logicalCPUCount)
        memoryTotal = try values.decode(UInt64.self, forKey: .memoryTotal)
        memoryUsed = try values.decode(UInt64.self, forKey: .memoryUsed)
        memoryAvailable = try values.decode(UInt64.self, forKey: .memoryAvailable)
        memoryCached = try values.decode(UInt64.self, forKey: .memoryCached)
        swapUsed = try values.decode(UInt64.self, forKey: .swapUsed)
        swapInPerSecond = try values.decodeIfPresent(Double.self, forKey: .swapInPerSecond) ?? 0
        swapOutPerSecond = try values.decodeIfPresent(Double.self, forKey: .swapOutPerSecond) ?? 0
        compressedMemoryBytes = try values.decodeIfPresent(
            UInt64.self,
            forKey: .compressedMemoryBytes
        ) ?? 0
        compressionBytesPerSecond = try values.decodeIfPresent(
            Double.self,
            forKey: .compressionBytesPerSecond
        ) ?? 0
        decompressionBytesPerSecond = try values.decodeIfPresent(
            Double.self,
            forKey: .decompressionBytesPerSecond
        ) ?? 0
        memoryPressure = try values.decode(Double.self, forKey: .memoryPressure)
        memoryPressureLevel = try values.decode(PressureLevel.self, forKey: .memoryPressureLevel)
        temperatureCelsius = try values.decodeIfPresent(Double.self, forKey: .temperatureCelsius)
        temperatureSource = try values.decode(TemperatureSource.self, forKey: .temperatureSource)
        thermalPressureLevel = try values.decode(PressureLevel.self, forKey: .thermalPressureLevel)
        gpuUsage = try values.decodeIfPresent(Double.self, forKey: .gpuUsage)
        gpuPressure = try values.decodeIfPresent(Double.self, forKey: .gpuPressure)
        gpuPressureLevel = try values.decode(PressureLevel.self, forKey: .gpuPressureLevel)
        gpuMemoryUsedBytes = try values.decodeIfPresent(UInt64.self, forKey: .gpuMemoryUsedBytes)
        gpuMemoryRecommendedBytes = try values.decodeIfPresent(
            UInt64.self,
            forKey: .gpuMemoryRecommendedBytes
        )
        gpuMemoryPressure = try values.decodeIfPresent(Double.self, forKey: .gpuMemoryPressure)
        fans = try values.decode([FanSample].self, forKey: .fans)
        networkDownloadPerSecond = try values.decode(Double.self, forKey: .networkDownloadPerSecond)
        networkUploadPerSecond = try values.decode(Double.self, forKey: .networkUploadPerSecond)
        diskReadPerSecond = try values.decode(Double.self, forKey: .diskReadPerSecond)
        diskWritePerSecond = try values.decode(Double.self, forKey: .diskWritePerSecond)
        diskCapacityBytes = try values.decodeIfPresent(UInt64.self, forKey: .diskCapacityBytes)
        diskAvailableBytes = try values.decodeIfPresent(UInt64.self, forKey: .diskAvailableBytes)
        uptime = try values.decode(TimeInterval.self, forKey: .uptime)
        processCPUUsage = try values.decode(Double.self, forKey: .processCPUUsage)
        processMemoryBytes = try values.decode(UInt64.self, forKey: .processMemoryBytes)
        processCount = try values.decode(Int.self, forKey: .processCount)
        batteryPercent = try values.decodeIfPresent(Double.self, forKey: .batteryPercent)
        isOnExternalPower = try values.decodeIfPresent(Bool.self, forKey: .isOnExternalPower)
        isLowPowerModeEnabled = try values.decodeIfPresent(
            Bool.self,
            forKey: .isLowPowerModeEnabled
        ) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp
        case cpuUsage
        case cpuPressure
        case cpuPressureLevel
        case loadAverage1m
        case logicalCPUCount
        case memoryTotal
        case memoryUsed
        case memoryAvailable
        case memoryCached
        case swapUsed
        case swapInPerSecond
        case swapOutPerSecond
        case compressedMemoryBytes
        case compressionBytesPerSecond
        case decompressionBytesPerSecond
        case memoryPressure
        case memoryPressureLevel
        case temperatureCelsius
        case temperatureSource
        case thermalPressureLevel
        case gpuUsage
        case gpuPressure
        case gpuPressureLevel
        case gpuMemoryUsedBytes
        case gpuMemoryRecommendedBytes
        case gpuMemoryPressure
        case fans
        case networkDownloadPerSecond
        case networkUploadPerSecond
        case diskReadPerSecond
        case diskWritePerSecond
        case diskCapacityBytes
        case diskAvailableBytes
        case uptime
        case processCPUUsage
        case processMemoryBytes
        case processCount
        case batteryPercent
        case isOnExternalPower
        case isLowPowerModeEnabled
    }
}

extension SystemSample {
    static let placeholder = SystemSample(
        timestamp: .now,
        cpuUsage: 0,
        cpuPressure: 0,
        cpuPressureLevel: .unavailable,
        loadAverage1m: 0,
        logicalCPUCount: ProcessInfo.processInfo.activeProcessorCount,
        memoryTotal: ProcessInfo.processInfo.physicalMemory,
        memoryUsed: 0,
        memoryAvailable: ProcessInfo.processInfo.physicalMemory,
        memoryCached: 0,
        swapUsed: 0,
        swapInPerSecond: 0,
        swapOutPerSecond: 0,
        compressedMemoryBytes: 0,
        compressionBytesPerSecond: 0,
        decompressionBytesPerSecond: 0,
        memoryPressure: 0,
        memoryPressureLevel: .unavailable,
        temperatureCelsius: nil,
        temperatureSource: .unavailable,
        thermalPressureLevel: .unavailable,
        gpuUsage: nil,
        gpuPressure: nil,
        gpuPressureLevel: .unavailable,
        gpuMemoryUsedBytes: nil,
        gpuMemoryRecommendedBytes: nil,
        gpuMemoryPressure: nil,
        fans: [],
        networkDownloadPerSecond: 0,
        networkUploadPerSecond: 0,
        diskReadPerSecond: 0,
        diskWritePerSecond: 0,
        diskCapacityBytes: nil,
        diskAvailableBytes: nil,
        uptime: ProcessInfo.processInfo.systemUptime,
        processCPUUsage: 0,
        processMemoryBytes: 0,
        processCount: 0,
        batteryPercent: nil,
        isOnExternalPower: nil,
        isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
    )
}
