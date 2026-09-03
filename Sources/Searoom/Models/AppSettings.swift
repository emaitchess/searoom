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
    case networkUpDown
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
        case .networkUpDown: "Network Upload/Download"
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

    static let maximumCount = 5

    /// Drops duplicates and anything past the cap. An empty result is returned
    /// as empty rather than replaced with the defaults: selecting nothing is a
    /// deliberate choice that means the mark-only status item. Only a *missing*
    /// stored key falls back to `defaults`, which the decoder handles.
    static func normalized(_ metrics: [MenuBarMetric]) -> [MenuBarMetric] {
        var seen = Set<MenuBarMetric>()
        var result: [MenuBarMetric] = []
        for metric in metrics where seen.insert(metric).inserted {
            result.append(metric)
            if result.count == maximumCount { break }
        }
        return result
    }

    /// Translates a pre-0.3 archive, which described the menu bar with a preset
    /// name, into the equivalent metric list. Each row reproduces exactly what
    /// that preset rendered, so an upgrade shows what it showed before.
    ///
    /// `llm` is the one lossy row: it drew `RAM used/total`, which no single
    /// metric expresses, so the total is lost.
    static func migrated(preset: String?, custom: [MenuBarMetric]?) -> [MenuBarMetric] {
        switch preset {
        case "custom": normalized(custom ?? defaults)
        case "minimal": []
        case "balanced": [.cpuUsage, .memoryUsed]
        case "reserve": [.memoryFree, .swapUsed]
        case "pressure": [.memoryPressure, .thermalPressure]
        case "llm": [.memoryUsed, .temperature, .gpuMemory]
        case "compute": [.cpuUsage, .gpuUsage]
        case "network": [.networkDownload, .networkUpload]
        case "disk": [.diskRead, .diskWrite]
        case "swap": [.swapIn, .swapOut]
        case "thermal": [.temperature, .fan]
        case "power": [.power]
        // A fresh install, or a preset some future build invented. Any stored
        // selection is more faithful than the defaults, so prefer it.
        default: custom.map(normalized) ?? defaults
        }
    }
}

/// How the status item arranges each metric.
enum MenuBarLayout: String, CaseIterable, Codable, Sendable {
    /// Label above value. Roughly half the width of `inline`, at the cost of
    /// two small lines inside a menu bar that is only about 22pt tall.
    case stacked
    /// One line, label beside value. Larger text, considerably wider.
    case inline

    var title: String {
        switch self {
        case .stacked: "Stacked"
        case .inline: "Inline"
        }
    }
}

struct AppSettings: Codable, Equatable, Sendable {
    static let supportedSampleIntervals: [TimeInterval] = [1, 2, 5, 10]
    static let supportedHistoryMinutes = [15, 30, 60, 180]

    var sampleInterval: TimeInterval
    var historyMinutes: Int
    var globalShortcut: GlobalShortcut?
    var menuBarMetrics: [MenuBarMetric]
    var menuBarLayout: MenuBarLayout
    var dashboardSectionOrder: [DashboardSection]
    var hasCompletedLaunchAtLoginPrompt: Bool

    init(
        sampleInterval: TimeInterval = 2,
        historyMinutes: Int = 30,
        globalShortcut: GlobalShortcut? = nil,
        menuBarMetrics: [MenuBarMetric] = MenuBarMetric.defaults,
        menuBarLayout: MenuBarLayout = .stacked,
        dashboardSectionOrder: [DashboardSection] = DashboardSection.defaults,
        hasCompletedLaunchAtLoginPrompt: Bool = false
    ) {
        self.sampleInterval = sampleInterval
        self.historyMinutes = historyMinutes
        self.globalShortcut = globalShortcut
        self.menuBarMetrics = MenuBarMetric.normalized(menuBarMetrics)
        self.menuBarLayout = menuBarLayout
        self.dashboardSectionOrder = DashboardSection.normalized(dashboardSectionOrder)
        self.hasCompletedLaunchAtLoginPrompt = hasCompletedLaunchAtLoginPrompt
        normalize()
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sampleInterval = try values.decodeIfPresent(TimeInterval.self, forKey: .sampleInterval) ?? 2
        historyMinutes = try values.decodeIfPresent(Int.self, forKey: .historyMinutes) ?? 30
        globalShortcut = try values.decodeIfPresent(GlobalShortcut.self, forKey: .globalShortcut)
        // Menu-bar metrics replaced the preset system. Read the current key
        // when it is there; otherwise translate whatever the old build stored,
        // so an upgrade keeps showing what it showed before. Decoding by raw
        // name means a metric retired later is dropped rather than failing the
        // whole archive.
        if let names = try values.decodeIfPresent([String].self, forKey: .menuBarMetrics) {
            menuBarMetrics = MenuBarMetric.normalized(names.compactMap(MenuBarMetric.init(rawValue:)))
        } else {
            let legacyNames = try values.decodeIfPresent([String].self, forKey: .customMenuBarMetrics)
            menuBarMetrics = MenuBarMetric.migrated(
                preset: try values.decodeIfPresent(String.self, forKey: .menuBarPreset),
                custom: legacyNames?.compactMap(MenuBarMetric.init(rawValue:))
            )
        }
        // Decoded by raw name so an unknown layout falls back rather than
        // failing the archive.
        let layoutName = try values.decodeIfPresent(String.self, forKey: .menuBarLayout)
        menuBarLayout = layoutName.flatMap(MenuBarLayout.init(rawValue:)) ?? .stacked
        // Decoded by raw name so a section retired in a later build is dropped
        // rather than failing the whole archive; normalization refills the gap.
        let sectionNames = try values.decodeIfPresent([String].self, forKey: .dashboardSectionOrder)
        let sections = sectionNames?.compactMap(DashboardSection.init(rawValue:))
            ?? DashboardSection.defaults
        dashboardSectionOrder = DashboardSection.normalized(sections)
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
        menuBarMetrics = MenuBarMetric.normalized(menuBarMetrics)
        dashboardSectionOrder = DashboardSection.normalized(dashboardSectionOrder)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(sampleInterval, forKey: .sampleInterval)
        try values.encode(historyMinutes, forKey: .historyMinutes)
        try values.encodeIfPresent(globalShortcut, forKey: .globalShortcut)
        try values.encode(menuBarMetrics, forKey: .menuBarMetrics)
        try values.encode(menuBarLayout.rawValue, forKey: .menuBarLayout)
        try values.encode(dashboardSectionOrder, forKey: .dashboardSectionOrder)
        try values.encode(hasCompletedLaunchAtLoginPrompt, forKey: .hasCompletedLaunchAtLoginPrompt)
    }

    private enum CodingKeys: String, CodingKey {
        case sampleInterval
        case historyMinutes
        case globalShortcut
        case menuBarMetrics
        case menuBarLayout
        case dashboardSectionOrder
        // Read during migration, never written again.
        case menuBarPreset
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
