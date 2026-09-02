import Foundation

enum MenuBarMetric: String, CaseIterable, Codable, Sendable {
    case cpuUsage
    case cpuPressure
    case memoryUsed
    case memoryFree
    case memoryFreeUsed
    case memoryPressure
    case swapUsed
    case swapIn
    case swapOut
    case temperature
    case thermalPressure
    case gpuUsage
    case gpuPressure
    case gpuMemory
    case networkDownload
    case networkUpload
    case diskRead
    case diskWrite
    case diskFree
    case fan
    case power
    case uptime
    case processCPU
    case processMemory

    static let defaults: [MenuBarMetric] = [.cpuUsage, .memoryUsed, .temperature]

    var title: String {
        switch self {
        case .cpuUsage: "CPU Usage"
        case .cpuPressure: "CPU Pressure"
        case .memoryUsed: "RAM Used"
        case .memoryFree: "RAM Free"
        case .memoryFreeUsed: "RAM Free / Used"
        case .memoryPressure: "Memory Pressure"
        case .swapUsed: "Swap Used"
        case .swapIn: "Swap In"
        case .swapOut: "Swap Out"
        case .temperature: "Temperature"
        case .thermalPressure: "Thermal Pressure"
        case .gpuUsage: "GPU Usage"
        case .gpuPressure: "GPU Pressure"
        case .gpuMemory: "GPU Memory"
        case .networkDownload: "Network Download"
        case .networkUpload: "Network Upload"
        case .diskRead: "Disk Read"
        case .diskWrite: "Disk Write"
        case .diskFree: "Disk Free"
        case .fan: "Fan Activity"
        case .power: "Power"
        case .uptime: "Uptime"
        case .processCPU: "Searoom CPU"
        case .processMemory: "Searoom RAM"
        }
    }

    static func normalized(_ metrics: [MenuBarMetric]) -> [MenuBarMetric] {
        var seen = Set<MenuBarMetric>()
        var result: [MenuBarMetric] = []
        for metric in metrics where seen.insert(metric).inserted {
            result.append(metric)
            if result.count == 3 { break }
        }
        return result.isEmpty ? defaults : result
    }
}

enum MenuBarPreset: String, CaseIterable, Codable, Sendable {
    case balanced
    case reserve
    case pressure
    case llm
    case compute
    case network
    case disk
    case swap
    case thermal
    case power
    case custom
    case minimal

    var title: String {
        switch self {
        case .balanced: "Balanced"
        case .reserve: "Reserve"
        case .pressure: "Pressure"
        case .llm: "LLM"
        case .compute: "Compute"
        case .network: "Network"
        case .disk: "Disk I/O"
        case .swap: "Swap Activity"
        case .thermal: "Thermal"
        case .power: "Power"
        case .custom: "Custom"
        case .minimal: "Minimal"
        }
    }
}

struct AppSettings: Codable, Equatable, Sendable {
    static let supportedSampleIntervals: [TimeInterval] = [1, 2, 5, 10]
    static let supportedHistoryMinutes = [15, 30, 60, 180]

    var sampleInterval: TimeInterval
    var menuBarPreset: MenuBarPreset
    var historyMinutes: Int
    var globalShortcut: GlobalShortcut?
    var customMenuBarMetrics: [MenuBarMetric]
    var hasCompletedLaunchAtLoginPrompt: Bool

    init(
        sampleInterval: TimeInterval = 2,
        menuBarPreset: MenuBarPreset = .balanced,
        historyMinutes: Int = 30,
        globalShortcut: GlobalShortcut? = nil,
        customMenuBarMetrics: [MenuBarMetric] = MenuBarMetric.defaults,
        hasCompletedLaunchAtLoginPrompt: Bool = false
    ) {
        self.sampleInterval = sampleInterval
        self.menuBarPreset = menuBarPreset
        self.historyMinutes = historyMinutes
        self.globalShortcut = globalShortcut
        self.customMenuBarMetrics = MenuBarMetric.normalized(customMenuBarMetrics)
        self.hasCompletedLaunchAtLoginPrompt = hasCompletedLaunchAtLoginPrompt
        normalize()
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sampleInterval = try values.decodeIfPresent(TimeInterval.self, forKey: .sampleInterval) ?? 2
        menuBarPreset = try values.decodeIfPresent(MenuBarPreset.self, forKey: .menuBarPreset) ?? .balanced
        historyMinutes = try values.decodeIfPresent(Int.self, forKey: .historyMinutes) ?? 30
        globalShortcut = try values.decodeIfPresent(GlobalShortcut.self, forKey: .globalShortcut)
        let customMetricNames = try values.decodeIfPresent(
            [String].self,
            forKey: .customMenuBarMetrics
        )
        let customMetrics = customMetricNames?.compactMap(MenuBarMetric.init(rawValue:))
            ?? MenuBarMetric.defaults
        customMenuBarMetrics = MenuBarMetric.normalized(customMetrics)
        // An existing archive proves Searoom has run before this prompt existed.
        hasCompletedLaunchAtLoginPrompt = try values.decodeIfPresent(
            Bool.self,
            forKey: .hasCompletedLaunchAtLoginPrompt
        ) ?? true
        normalize()
    }

    mutating func normalize() {
        if !sampleInterval.isFinite || !Self.supportedSampleIntervals.contains(sampleInterval) {
            sampleInterval = 2
        }
        if !Self.supportedHistoryMinutes.contains(historyMinutes) { historyMinutes = 30 }
        customMenuBarMetrics = MenuBarMetric.normalized(customMenuBarMetrics)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(sampleInterval, forKey: .sampleInterval)
        try values.encode(menuBarPreset, forKey: .menuBarPreset)
        try values.encode(historyMinutes, forKey: .historyMinutes)
        try values.encodeIfPresent(globalShortcut, forKey: .globalShortcut)
        try values.encode(customMenuBarMetrics, forKey: .customMenuBarMetrics)
        try values.encode(hasCompletedLaunchAtLoginPrompt, forKey: .hasCompletedLaunchAtLoginPrompt)
    }

    private enum CodingKeys: String, CodingKey {
        case sampleInterval
        case menuBarPreset
        case historyMinutes
        case globalShortcut
        case customMenuBarMetrics
        case hasCompletedLaunchAtLoginPrompt
    }
}

struct ShortcutModifiers: OptionSet, Codable, Equatable, Sendable {
    let rawValue: UInt32

    static let command = ShortcutModifiers(rawValue: 1 << 0)
    static let option = ShortcutModifiers(rawValue: 1 << 1)
    static let control = ShortcutModifiers(rawValue: 1 << 2)
    static let shift = ShortcutModifiers(rawValue: 1 << 3)

    var hasPrimaryModifier: Bool {
        contains(.command) || contains(.option) || contains(.control)
    }
}

struct GlobalShortcut: Codable, Equatable, Sendable {
    let keyCode: UInt16
    let modifiers: ShortcutModifiers
    let keyLabel: String

    var displayName: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result + keyLabel
    }
}
