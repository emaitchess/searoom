import Foundation

enum DashboardUnitTarget: Hashable, Sendable {
    case memory
    case temperature
    case network
    case diskIO
    case cache
    case swap
    case swapIO
    case compressedMemory
    case compression
    case gpuMemory
    case diskCapacity
    case processMemory

    var accessibilityName: String {
        switch self {
        case .memory: "memory"
        case .temperature: "temperature"
        case .network: "network throughput"
        case .diskIO: "disk throughput"
        case .cache: "cache"
        case .swap: "swap"
        case .swapIO: "swap throughput"
        case .compressedMemory: "compressed memory"
        case .compression: "memory compression"
        case .gpuMemory: "GPU memory"
        case .diskCapacity: "disk capacity"
        case .processMemory: "Searoom memory"
        }
    }

    fileprivate var family: UnitFamily {
        switch self {
        case .memory, .cache, .swap, .compressedMemory, .gpuMemory, .diskCapacity, .processMemory:
            .bytes
        case .temperature:
            .temperature
        case .network, .diskIO, .swapIO, .compression:
            .rate
        }
    }

    fileprivate var unitCount: Int {
        switch family {
        case .bytes: MetricByteUnit.allCases.count
        case .temperature: MetricTemperatureUnit.allCases.count
        case .rate: MetricRateUnit.allCases.count
        }
    }

    fileprivate enum UnitFamily: Equatable {
        case bytes
        case temperature
        case rate
    }
}

struct DashboardUnitState: Equatable, Sendable {
    private var selectedIndices: [DashboardUnitTarget: Int] = [:]

    mutating func cycle(_ target: DashboardUnitTarget) {
        selectedIndices[target] = (selectedIndex(for: target) + 1) % target.unitCount
    }

    func byteUnit(for target: DashboardUnitTarget) -> MetricByteUnit {
        guard target.family == .bytes else { return .gigabytes }
        return MetricByteUnit.allCases[selectedIndex(for: target)]
    }

    func temperatureUnit(for target: DashboardUnitTarget) -> MetricTemperatureUnit {
        guard target.family == .temperature else { return .celsius }
        return MetricTemperatureUnit.allCases[selectedIndex(for: target)]
    }

    func rateUnit(for target: DashboardUnitTarget) -> MetricRateUnit {
        guard target.family == .rate else { return .adaptive }
        return MetricRateUnit.allCases[selectedIndex(for: target)]
    }

    func unitLabel(for target: DashboardUnitTarget) -> String {
        switch target.family {
        case .bytes:
            byteUnit(for: target).label
        case .temperature:
            temperatureUnit(for: target).label
        case .rate:
            rateUnit(for: target).label
        }
    }

    private func selectedIndex(for target: DashboardUnitTarget) -> Int {
        min(target.unitCount - 1, max(0, selectedIndices[target] ?? 0))
    }
}
