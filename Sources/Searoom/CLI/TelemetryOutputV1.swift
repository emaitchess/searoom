import Foundation

/// Version 1 of the public CLI telemetry contract. These types exist
/// independently of the persisted `SystemSample` shape: their key names,
/// units, and nullability are a compatibility surface, so nothing here may
/// change without a new schema version.
///
/// Encoding rules (see the bundled telemetry-v1 schema):
/// - Fractions use the closed range 0...1 and names ending in `Fraction`.
/// - Byte sizes, rates, durations, and temperatures use explicit unit suffixes.
/// - Dates are UTC RFC 3339 with fractional seconds.
/// - Pressure levels are lowercase strings.
/// - Unavailable readings are explicit `null`, never fabricated zeroes.
/// - `legacyUnknown` readings keep their stored value but are flagged.
enum TelemetryOutputV1 {
    static let schemaVersion = 1
    static let schemaURL = "https://searoom.app/schemas/telemetry-v1.schema.json"
    /// Persisted history is written at most once per minute, so a reader can
    /// lag the running app by about this much.
    static let approximateHistoryLagSeconds = 60

    static func encoder(pretty: Bool) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(CLIDateFormat.string(from: date))
        }
        return encoder
    }

    static func encode<T: Encodable>(_ value: T, pretty: Bool) throws -> Data {
        try encoder(pretty: pretty).encode(value)
    }

    /// Non-finite values are rejected at projection time so encoding can never
    /// fail on a collector that leaked one through.
    static func finite(_ value: Double) -> Double? {
        value.isFinite ? value : nil
    }
}

/// Where a document's data came from. `watch` reuses the `sample` source.
struct TelemetrySourceV1: Encodable, Equatable {
    let kind: String
    let producer: String
    let requestedIntervalSeconds: Int?

    static func live(intervalSeconds: Int?) -> TelemetrySourceV1 {
        TelemetrySourceV1(
            kind: "live",
            producer: "searoom-cli",
            requestedIntervalSeconds: intervalSeconds
        )
    }

    static var persistedHistory: TelemetrySourceV1 {
        TelemetrySourceV1(kind: "persisted", producer: "searoom-app", requestedIntervalSeconds: nil)
    }
}

struct TelemetrySampleV1: Encodable, Equatable {
    let timestamp: Date
    let uptimeSeconds: Double
    let cpu: CPU
    let memory: Memory
    let thermal: Thermal
    let gpu: GPU
    let network: Network
    let disk: Disk
    let power: Power
    let system: System
    let observer: Observer

    struct CPU: Encodable, Equatable {
        let usageFraction: Double?
        let pressureFraction: Double?
        let pressureLevel: String?
        let pressureKind: String
        let pressureFormula: String
        let loadAverage1m: Double?
        let logicalCPUCount: Int
        let availability: String
    }

    struct Memory: Encodable, Equatable {
        let totalBytes: UInt64
        let usedBytes: UInt64?
        let availableBytes: UInt64?
        let cachedBytes: UInt64?
        let compressedBytes: UInt64?
        let swapUsedBytes: UInt64?
        let swapInBytesPerSecond: Double?
        let swapOutBytesPerSecond: Double?
        let compressionBytesPerSecond: Double?
        let decompressionBytesPerSecond: Double?
        let pressureFraction: Double?
        let pressureLevel: String?
        let systemPressureLevel: String?
        let systemPressureSource: String
        let vmStatisticsAvailability: String
        let swapUsageAvailability: String
        let swapIOAvailability: String
        let compressionIOAvailability: String
    }

    struct Fan: Encodable, Equatable {
        let name: String
        let rpm: Double
    }

    struct Thermal: Encodable, Equatable {
        let temperatureCelsius: Double?
        let temperatureSource: String
        let systemPressureLevel: String
        let systemPressureSource: String
        let fans: [Fan]
        let temperatureAvailability: String
        let fansAvailability: String
    }

    struct GPU: Encodable, Equatable {
        let usageFraction: Double?
        let pressureFraction: Double?
        let pressureLevel: String?
        let pressureKind: String
        let pressureFormula: String
        let memoryUsedBytes: UInt64?
        let memoryRecommendedBytes: UInt64?
        let workingSetRatioFraction: Double?
        let workingSetHeadroomBytes: UInt64?
        let availability: String
    }

    struct Network: Encodable, Equatable {
        let downloadBytesPerSecond: Double?
        let uploadBytesPerSecond: Double?
        let availability: String
    }

    struct Disk: Encodable, Equatable {
        let readBytesPerSecond: Double?
        let writeBytesPerSecond: Double?
        let capacityBytes: UInt64?
        let availableBytes: UInt64?
        let usedBytes: UInt64?
        let usedFraction: Double?
        let ioAvailability: String
        let capacityAvailability: String
    }

    struct Power: Encodable, Equatable {
        let batteryFraction: Double?
        let externalPower: Bool?
        let lowPowerModeEnabled: Bool
        let availability: String
    }

    struct System: Encodable, Equatable {
        let overallPressureLevel: String
        let processCount: Int?
    }

    struct Observer: Encodable, Equatable {
        let kind: String
        let cpuUsage: Double?
        let residentMemoryBytes: UInt64?
        let cpuAvailability: String
        let memoryAvailability: String
    }

    /// Projects one stored sample into the public v1 shape. `observerKind`
    /// distinguishes live CLI sampling from values persisted by the app.
    static func make(
        from sample: SystemSample,
        observerKind: String
    ) -> TelemetrySampleV1 {
        let availability = sample.availability

        func value<T>(_ reading: T, _ state: ReadingAvailability) -> T? {
            state == .unavailable ? nil : reading
        }
        func numeric(_ reading: Double, _ state: ReadingAvailability) -> Double? {
            state == .unavailable ? nil : TelemetryOutputV1.finite(reading)
        }

        let gpuWorkingSetRatio = sample.gpuMemoryPressure.flatMap(TelemetryOutputV1.finite)
        let gpuHeadroom: UInt64? = {
            guard let used = sample.gpuMemoryUsedBytes,
                  let recommended = sample.gpuMemoryRecommendedBytes,
                  recommended >= used else { return nil }
            return recommended - used
        }()

        return TelemetrySampleV1(
            timestamp: sample.timestamp,
            uptimeSeconds: TelemetryOutputV1.finite(sample.uptime) ?? 0,
            cpu: CPU(
                usageFraction: numeric(sample.cpuUsage, availability.cpuUsageLoad),
                pressureFraction: numeric(sample.cpuPressure, availability.cpuUsageLoad),
                pressureLevel: value(sample.cpuPressureLevel.outputLabel, availability.cpuUsageLoad),
                pressureKind: "derived",
                pressureFormula: "max(cpuUsage, loadAverage1m/logicalCPUCount)",
                loadAverage1m: sample.loadAverage1m >= 0 && sample.loadAverage1m.isFinite ? sample.loadAverage1m : nil,
                logicalCPUCount: sample.logicalCPUCount,
                availability: availability.cpuUsageLoad.rawValue
            ),
            memory: Memory(
                totalBytes: sample.memoryTotal,
                usedBytes: value(sample.memoryUsed, availability.vmStatistics),
                availableBytes: value(sample.memoryAvailable, availability.vmStatistics),
                cachedBytes: value(sample.memoryCached, availability.vmStatistics),
                compressedBytes: value(sample.compressedMemoryBytes, availability.vmStatistics),
                swapUsedBytes: value(sample.swapUsed, availability.swapUsage),
                swapInBytesPerSecond: numeric(sample.swapInPerSecond, availability.swapIO),
                swapOutBytesPerSecond: numeric(sample.swapOutPerSecond, availability.swapIO),
                compressionBytesPerSecond: numeric(sample.compressionBytesPerSecond, availability.compressionIO),
                decompressionBytesPerSecond: numeric(sample.decompressionBytesPerSecond, availability.compressionIO),
                pressureFraction: numeric(sample.memoryPressure, availability.vmStatistics),
                pressureLevel: value(sample.memoryPressureLevel.outputLabel, availability.vmStatistics),
                systemPressureLevel: sample.memorySystemPressureLevel?.outputLabel,
                systemPressureSource: "kern.memorystatus_vm_pressure_level",
                vmStatisticsAvailability: availability.vmStatistics.rawValue,
                swapUsageAvailability: availability.swapUsage.rawValue,
                swapIOAvailability: availability.swapIO.rawValue,
                compressionIOAvailability: availability.compressionIO.rawValue
            ),
            thermal: Thermal(
                temperatureCelsius: sample.temperatureCelsius.flatMap(TelemetryOutputV1.finite),
                temperatureSource: sample.temperatureSource.rawValue,
                systemPressureLevel: sample.thermalPressureLevel.outputLabel,
                systemPressureSource: "ProcessInfo.thermalState",
                fans: sample.fans.map { Fan(name: $0.name, rpm: $0.rpm) },
                temperatureAvailability: availability.temperature.rawValue,
                fansAvailability: availability.fans.rawValue
            ),
            gpu: GPU(
                usageFraction: sample.gpuUsage.flatMap(TelemetryOutputV1.finite),
                pressureFraction: sample.gpuPressure.flatMap(TelemetryOutputV1.finite),
                pressureLevel: sample.gpuPressureLevel == .unavailable ? nil : sample.gpuPressureLevel.outputLabel,
                pressureKind: "derived",
                pressureFormula: "max(gpuUsage, gpuMemoryUsedBytes/gpuMemoryRecommendedBytes)",
                memoryUsedBytes: sample.gpuMemoryUsedBytes,
                memoryRecommendedBytes: sample.gpuMemoryRecommendedBytes,
                workingSetRatioFraction: gpuWorkingSetRatio,
                workingSetHeadroomBytes: gpuHeadroom,
                availability: availability.gpu.rawValue
            ),
            network: Network(
                downloadBytesPerSecond: numeric(sample.networkDownloadPerSecond, availability.networkIO),
                uploadBytesPerSecond: numeric(sample.networkUploadPerSecond, availability.networkIO),
                availability: availability.networkIO.rawValue
            ),
            disk: Disk(
                readBytesPerSecond: numeric(sample.diskReadPerSecond, availability.diskIO),
                writeBytesPerSecond: numeric(sample.diskWritePerSecond, availability.diskIO),
                capacityBytes: sample.diskCapacityBytes,
                availableBytes: sample.diskAvailableBytes,
                usedBytes: sample.diskUsedBytes,
                usedFraction: sample.diskUsedFraction.flatMap(TelemetryOutputV1.finite),
                ioAvailability: availability.diskIO.rawValue,
                capacityAvailability: availability.diskCapacity.rawValue
            ),
            power: Power(
                batteryFraction: sample.batteryPercent.flatMap(TelemetryOutputV1.finite),
                externalPower: sample.isOnExternalPower,
                lowPowerModeEnabled: sample.isLowPowerModeEnabled,
                availability: availability.battery.rawValue
            ),
            system: System(
                overallPressureLevel: sample.overallPressureLevel.outputLabel,
                processCount: availability.processCount == .unavailable ? nil : sample.processCount
            ),
            observer: Observer(
                kind: observerKind,
                cpuUsage: numeric(sample.processCPUUsage, availability.processCPU),
                residentMemoryBytes: value(sample.processMemoryBytes, availability.processMemory),
                cpuAvailability: availability.processCPU.rawValue,
                memoryAvailability: availability.processMemory.rawValue
            )
        )
    }
}

/// The JSON envelope shared by every versioned CLI document.
struct SampleDocumentV1: Encodable {
    let schemaURL: String
    let schemaVersion: Int
    let document: String
    let searoomVersion: String
    let generatedAt: Date
    let source: TelemetrySourceV1
    let sample: TelemetrySampleV1

    enum CodingKeys: String, CodingKey {
        case schemaURL = "$schema"
        case schemaVersion
        case document
        case searoomVersion
        case generatedAt
        case source
        case sample
    }

    init(sample: TelemetrySampleV1, intervalSeconds: Int?, generatedAt: Date, version: CLIVersionInfo) {
        schemaURL = TelemetryOutputV1.schemaURL
        schemaVersion = TelemetryOutputV1.schemaVersion
        document = "sample"
        searoomVersion = version.searoomVersion
        self.generatedAt = generatedAt
        source = TelemetrySourceV1.live(intervalSeconds: intervalSeconds)
        self.sample = sample
    }
}

struct VersionDocumentV1: Encodable {
    let schemaURL: String
    let schemaVersion: Int
    let document: String
    let searoomVersion: String
    let buildNumber: String
    let telemetrySchemaVersion: Int
    let macosFloor: String
    let generatedAt: Date

    init(version: CLIVersionInfo, generatedAt: Date) {
        schemaURL = TelemetryOutputV1.schemaURL
        schemaVersion = TelemetryOutputV1.schemaVersion
        document = "version"
        searoomVersion = version.searoomVersion
        buildNumber = version.buildNumber
        telemetrySchemaVersion = TelemetryOutputV1.schemaVersion
        macosFloor = version.macosFloor
        self.generatedAt = generatedAt
    }

    enum CodingKeys: String, CodingKey {
        case schemaURL = "$schema"
        case schemaVersion
        case document
        case searoomVersion
        case buildNumber
        case telemetrySchemaVersion
        case macosFloor
        case generatedAt
    }
}

struct HelpCatalogDocumentV1: Encodable {
    let schemaURL: String
    let schemaVersion: Int
    let document: String
    let searoomVersion: String
    let generatedAt: Date
    let catalog: CLICommandCatalog

    init(catalog: CLICommandCatalog, version: CLIVersionInfo, generatedAt: Date) {
        schemaURL = TelemetryOutputV1.schemaURL
        schemaVersion = TelemetryOutputV1.schemaVersion
        document = "help-catalog"
        searoomVersion = version.searoomVersion
        self.generatedAt = generatedAt
        self.catalog = catalog
    }

    enum CodingKeys: String, CodingKey {
        case schemaURL = "$schema"
        case schemaVersion
        case document
        case searoomVersion
        case generatedAt
        case catalog
    }
}

struct HistoryDocumentV1: Encodable {
    struct Sustained: Encodable, Equatable {
        let level: String
        let durationSeconds: Double
        let boundedByHistoryWindow: Bool
    }

    let schemaURL: String
    let schemaVersion: Int
    let document: String
    let searoomVersion: String
    let generatedAt: Date
    let source: TelemetrySourceV1
    let archivePath: String
    let approximateLagSeconds: Int
    let sampleCount: Int
    /// Computed from the full persisted archive before any `--since`,
    /// `--until`, or `--limit` filtering, so a bounded output never makes a
    /// run look shorter than it was.
    let sustainedBeforeFiltering: Sustained?
    let samples: [TelemetrySampleV1]

    init(
        samples: [TelemetrySampleV1],
        archive: [SystemSample],
        archivePath: String,
        version: CLIVersionInfo,
        generatedAt: Date
    ) {
        schemaURL = TelemetryOutputV1.schemaURL
        schemaVersion = TelemetryOutputV1.schemaVersion
        document = "history"
        searoomVersion = version.searoomVersion
        self.generatedAt = generatedAt
        source = .persistedHistory
        self.archivePath = archivePath
        approximateLagSeconds = TelemetryOutputV1.approximateHistoryLagSeconds
        sampleCount = samples.count
        if let reading = SustainedPressure.duration(in: archive), reading.level != .unavailable {
            sustainedBeforeFiltering = Sustained(
                level: reading.level.outputLabel,
                durationSeconds: reading.duration,
                boundedByHistoryWindow: reading.boundedByHistoryWindow
            )
        } else {
            sustainedBeforeFiltering = nil
        }
        self.samples = samples
    }

    enum CodingKeys: String, CodingKey {
        case schemaURL = "$schema"
        case schemaVersion
        case document
        case searoomVersion
        case generatedAt
        case source
        case archivePath
        case approximateLagSeconds
        case sampleCount
        case sustainedBeforeFiltering
        case samples
    }
}

/// One resource that is limiting the system right now. Ties are retained: if
/// CPU and GPU sit at the same level, both appear.
struct LimitingResourceV1: Encodable, Equatable {
    let resource: String
    let level: String
    let valueFraction: Double?
}

struct StatusDocumentV1: Encodable {
    struct HistoryContext: Encodable, Equatable {
        let lastTimestamp: Date?
        let lagSeconds: Double?
        let approximateLagSeconds: Int
        let usableForSustained: Bool
        let unusableReason: String?
    }

    struct Sustained: Encodable, Equatable {
        let level: String
        let durationSeconds: Double
        let boundedByHistoryWindow: Bool
    }

    struct Derived: Encodable, Equatable {
        let memoryUsedFraction: Double?
        let memoryCompressedFraction: Double?
        let gpuWorkingSetHeadroomBytes: UInt64?
        let diskUsedBytes: UInt64?
        let diskUsedFraction: Double?
        let powerStateLabel: String
        let swapActivityState: String
        let fanState: String
        let observerState: String
    }

    let schemaURL: String
    let schemaVersion: Int
    let document: String
    let searoomVersion: String
    let generatedAt: Date
    let source: TelemetrySourceV1
    let overallPressureLevel: String
    let limitingResources: [LimitingResourceV1]
    let derived: Derived
    let sustained: Sustained?
    let historyContext: HistoryContext
    let sample: TelemetrySampleV1

    init(
        sample: TelemetrySampleV1,
        raw: SystemSample,
        limiting: [LimitingResourceV1],
        derived: Derived,
        sustained: Sustained?,
        historyContext: HistoryContext,
        intervalSeconds: Int?,
        version: CLIVersionInfo,
        generatedAt: Date
    ) {
        schemaURL = TelemetryOutputV1.schemaURL
        schemaVersion = TelemetryOutputV1.schemaVersion
        document = "status"
        searoomVersion = version.searoomVersion
        self.generatedAt = generatedAt
        source = TelemetrySourceV1.live(intervalSeconds: intervalSeconds)
        overallPressureLevel = raw.overallPressureLevel.outputLabel
        self.limitingResources = limiting
        self.derived = derived
        self.sustained = sustained
        self.historyContext = historyContext
        self.sample = sample
    }

    enum CodingKeys: String, CodingKey {
        case schemaURL = "$schema"
        case schemaVersion
        case document
        case searoomVersion
        case generatedAt
        case source
        case overallPressureLevel
        case limitingResources
        case derived
        case sustained
        case historyContext
        case sample
    }
}

struct CapabilityV1: Encodable, Equatable {
    let group: String
    let availability: String
    let source: String
    let refreshCadenceSeconds: Int?
    let notes: String?
}

struct CapabilitiesDocumentV1: Encodable {
    let schemaURL: String
    let schemaVersion: Int
    let document: String
    let searoomVersion: String
    let generatedAt: Date
    let source: TelemetrySourceV1
    let groups: [CapabilityV1]

    init(groups: [CapabilityV1], intervalSeconds: Int?, version: CLIVersionInfo, generatedAt: Date) {
        schemaURL = TelemetryOutputV1.schemaURL
        schemaVersion = TelemetryOutputV1.schemaVersion
        document = "capabilities"
        searoomVersion = version.searoomVersion
        self.generatedAt = generatedAt
        source = TelemetrySourceV1.live(intervalSeconds: intervalSeconds)
        self.groups = groups
    }

    enum CodingKeys: String, CodingKey {
        case schemaURL = "$schema"
        case schemaVersion
        case document
        case searoomVersion
        case generatedAt
        case source
        case groups
    }
}

/// One canonical metric definition. The bundled `metrics.json` is the single
/// source for this shape; the human-readable Markdown catalog is rendered
/// from it at runtime.
struct MetricDefinitionV1: Codable, Equatable {
    struct Thresholds: Codable, Equatable {
        let elevated: Double
        let constrained: Double
        let critical: Double
    }

    let id: String
    let jsonPath: String
    let displayName: String
    let unit: String
    let range: String
    let nullable: Bool
    let source: String
    let sourceStability: String
    let refreshCadence: String
    let refreshCadenceSeconds: Int?
    let derivation: String?
    let thresholds: Thresholds?
    let firstSampleBehavior: String
    let rollbackBehavior: String
    let limitations: [String]
    let interpretationNotes: [String]
}

struct MetricCatalogDocumentV1: Encodable {
    let schemaURL: String
    let schemaVersion: Int
    let document: String
    let searoomVersion: String
    let generatedAt: Date
    let metrics: [MetricDefinitionV1]

    init(metrics: [MetricDefinitionV1], version: CLIVersionInfo, generatedAt: Date) {
        schemaURL = TelemetryOutputV1.schemaURL
        schemaVersion = TelemetryOutputV1.schemaVersion
        document = "metric-catalog"
        searoomVersion = version.searoomVersion
        self.generatedAt = generatedAt
        self.metrics = metrics
    }

    enum CodingKeys: String, CodingKey {
        case schemaURL = "$schema"
        case schemaVersion
        case document
        case searoomVersion
        case generatedAt
        case metrics
    }
}

extension PressureLevel {
    /// The public lowercase string form. Persisted samples keep integers; the
    /// CLI contract never exposes them.
    var outputLabel: String {
        switch self {
        case .nominal: "nominal"
        case .elevated: "elevated"
        case .constrained: "constrained"
        case .critical: "critical"
        case .unavailable: "unavailable"
        }
    }
}

extension SystemSample {
    var diskUsedBytes: UInt64? {
        guard let capacity = diskCapacityBytes, let available = diskAvailableBytes else { return nil }
        return capacity >= available ? capacity - available : nil
    }

    var diskUsedFraction: Double? {
        guard let capacity = diskCapacityBytes, capacity > 0,
              let used = diskUsedBytes else { return nil }
        return min(1, Double(used) / Double(capacity))
    }
}

/// Loads the bundled structured metric catalog. Shared by the `metrics`
/// command, self-test resource checks, and tests so there is exactly one
/// decoder for `metrics.json`.
enum CLIMetricResource {
    static func loadDefinitions(bundle: Bundle = .module) throws -> [MetricDefinitionV1] {
        for subdirectory in [nil, "CLI"] as [String?] {
            guard let url = bundle.url(
                forResource: "metrics",
                withExtension: "json",
                subdirectory: subdirectory
            ) else { continue }
            do {
                let data = try Data(contentsOf: url)
                return try JSONDecoder().decode([MetricDefinitionV1].self, from: data)
            } catch {
                throw CLIError(
                    exitCode: .softwareError,
                    message: "bundled metrics.json is invalid: \(error.localizedDescription)"
                )
            }
        }
        throw CLIError(exitCode: .softwareError, message: "bundled metrics.json is missing")
    }
}

/// App version metadata for `version` and every document envelope.
struct CLIVersionInfo {
    let searoomVersion: String
    let buildNumber: String
    let macosFloor: String

    static let macosFloorConstant = "14.0"

    static func current() -> CLIVersionInfo {
        resolve(info: Bundle.main.infoDictionary, executableURL: Bundle.main.executableURL)
    }

    /// The version reported through every document envelope.
    ///
    /// `Bundle.main` is derived from the path the process was launched with,
    /// and that path is not resolved through symlinks. Both supported ways of
    /// getting the command — Homebrew's `bin` link and `install-cli`'s
    /// `~/.local/bin/searoom` — are symlinks outside the bundle, so
    /// `Bundle.main` is the link's own directory and has no `Info.plist`.
    /// Resources still load, because SwiftPM's accessor searches the
    /// executable's directory as well, which is why this went unnoticed:
    /// only the version was wrong, and it was wrong on the common path.
    ///
    /// Resolve the executable and read the `.app` that encloses it. A build
    /// with no enclosing bundle, such as running straight out of `.build`,
    /// keeps the placeholder rather than inventing a number.
    static func resolve(info: [String: Any]?, executableURL: URL?) -> CLIVersionInfo {
        if let version = version(from: info) { return version }
        if let version = version(from: enclosingAppBundleInfo(executableURL: executableURL)) {
            return version
        }
        return CLIVersionInfo(searoomVersion: "0.0.0", buildNumber: "0", macosFloor: macosFloorConstant)
    }

    private static func version(from info: [String: Any]?) -> CLIVersionInfo? {
        guard let short = info?["CFBundleShortVersionString"] as? String,
              let build = info?["CFBundleVersion"] as? String
        else { return nil }
        return CLIVersionInfo(searoomVersion: short, buildNumber: build, macosFloor: macosFloorConstant)
    }

    /// `.../Searoom.app/Contents/MacOS/searoom` -> the `Searoom.app` bundle.
    private static func enclosingAppBundleInfo(executableURL: URL?) -> [String: Any]? {
        guard let executableURL else { return nil }
        let bundleURL = executableURL
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()  // MacOS
            .deletingLastPathComponent()  // Contents
            .deletingLastPathComponent()  // Searoom.app
        guard bundleURL.pathExtension == "app" else { return nil }
        return Bundle(url: bundleURL)?.infoDictionary
    }
}


/// Explicit-null encoding. The v1 contract requires unavailable values to
/// appear as JSON `null`, never as omitted keys, so every DTO with optional
/// fields encodes through this helper instead of `encodeIfPresent`.
private enum TelemetryNullEncoding {
    static func encode<T: Encodable, K: CodingKey>(
        _ value: T?,
        _ key: K,
        _ container: inout KeyedEncodingContainer<K>
    ) throws {
        if let value {
            try container.encode(value, forKey: key)
        } else {
            try container.encodeNil(forKey: key)
        }
    }
}

extension TelemetrySourceV1 {
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(producer, forKey: .producer)
        try TelemetryNullEncoding.encode(requestedIntervalSeconds, .requestedIntervalSeconds, &container)
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case producer
        case requestedIntervalSeconds
    }
}

extension TelemetrySampleV1 {
    private enum SectionKeys: String, CodingKey {
        case timestamp
        case uptimeSeconds
        case cpu
        case memory
        case thermal
        case gpu
        case network
        case disk
        case power
        case system
        case observer
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: SectionKeys.self)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(uptimeSeconds, forKey: .uptimeSeconds)
        try container.encode(cpu, forKey: .cpu)
        try container.encode(memory, forKey: .memory)
        try container.encode(thermal, forKey: .thermal)
        try container.encode(gpu, forKey: .gpu)
        try container.encode(network, forKey: .network)
        try container.encode(disk, forKey: .disk)
        try container.encode(power, forKey: .power)
        try container.encode(system, forKey: .system)
        try container.encode(observer, forKey: .observer)
    }
}

extension TelemetrySampleV1.CPU {
    private enum Keys: String, CodingKey {
        case usageFraction, pressureFraction, pressureLevel, pressureKind
        case pressureFormula, loadAverage1m, logicalCPUCount, availability
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try TelemetryNullEncoding.encode(usageFraction, .usageFraction, &container)
        try TelemetryNullEncoding.encode(pressureFraction, .pressureFraction, &container)
        try TelemetryNullEncoding.encode(pressureLevel, .pressureLevel, &container)
        try container.encode(pressureKind, forKey: .pressureKind)
        try container.encode(pressureFormula, forKey: .pressureFormula)
        try TelemetryNullEncoding.encode(loadAverage1m, .loadAverage1m, &container)
        try container.encode(logicalCPUCount, forKey: .logicalCPUCount)
        try container.encode(availability, forKey: .availability)
    }
}

extension TelemetrySampleV1.Memory {
    private enum Keys: String, CodingKey {
        case totalBytes, usedBytes, availableBytes, cachedBytes, compressedBytes
        case swapUsedBytes, swapInBytesPerSecond, swapOutBytesPerSecond
        case compressionBytesPerSecond, decompressionBytesPerSecond
        case pressureFraction, pressureLevel, systemPressureLevel, systemPressureSource
        case vmStatisticsAvailability, swapUsageAvailability, swapIOAvailability
        case compressionIOAvailability
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(totalBytes, forKey: .totalBytes)
        try TelemetryNullEncoding.encode(usedBytes, .usedBytes, &container)
        try TelemetryNullEncoding.encode(availableBytes, .availableBytes, &container)
        try TelemetryNullEncoding.encode(cachedBytes, .cachedBytes, &container)
        try TelemetryNullEncoding.encode(compressedBytes, .compressedBytes, &container)
        try TelemetryNullEncoding.encode(swapUsedBytes, .swapUsedBytes, &container)
        try TelemetryNullEncoding.encode(swapInBytesPerSecond, .swapInBytesPerSecond, &container)
        try TelemetryNullEncoding.encode(swapOutBytesPerSecond, .swapOutBytesPerSecond, &container)
        try TelemetryNullEncoding.encode(compressionBytesPerSecond, .compressionBytesPerSecond, &container)
        try TelemetryNullEncoding.encode(decompressionBytesPerSecond, .decompressionBytesPerSecond, &container)
        try TelemetryNullEncoding.encode(pressureFraction, .pressureFraction, &container)
        try TelemetryNullEncoding.encode(pressureLevel, .pressureLevel, &container)
        try TelemetryNullEncoding.encode(systemPressureLevel, .systemPressureLevel, &container)
        try container.encode(systemPressureSource, forKey: .systemPressureSource)
        try container.encode(vmStatisticsAvailability, forKey: .vmStatisticsAvailability)
        try container.encode(swapUsageAvailability, forKey: .swapUsageAvailability)
        try container.encode(swapIOAvailability, forKey: .swapIOAvailability)
        try container.encode(compressionIOAvailability, forKey: .compressionIOAvailability)
    }
}

extension TelemetrySampleV1.Thermal {
    private enum Keys: String, CodingKey {
        case temperatureCelsius, temperatureSource, systemPressureLevel
        case systemPressureSource, fans, temperatureAvailability, fansAvailability
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try TelemetryNullEncoding.encode(temperatureCelsius, .temperatureCelsius, &container)
        try container.encode(temperatureSource, forKey: .temperatureSource)
        try container.encode(systemPressureLevel, forKey: .systemPressureLevel)
        try container.encode(systemPressureSource, forKey: .systemPressureSource)
        try container.encode(fans, forKey: .fans)
        try container.encode(temperatureAvailability, forKey: .temperatureAvailability)
        try container.encode(fansAvailability, forKey: .fansAvailability)
    }
}

extension TelemetrySampleV1.GPU {
    private enum Keys: String, CodingKey {
        case usageFraction, pressureFraction, pressureLevel, pressureKind
        case pressureFormula, memoryUsedBytes, memoryRecommendedBytes
        case workingSetRatioFraction, workingSetHeadroomBytes, availability
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try TelemetryNullEncoding.encode(usageFraction, .usageFraction, &container)
        try TelemetryNullEncoding.encode(pressureFraction, .pressureFraction, &container)
        try TelemetryNullEncoding.encode(pressureLevel, .pressureLevel, &container)
        try container.encode(pressureKind, forKey: .pressureKind)
        try container.encode(pressureFormula, forKey: .pressureFormula)
        try TelemetryNullEncoding.encode(memoryUsedBytes, .memoryUsedBytes, &container)
        try TelemetryNullEncoding.encode(memoryRecommendedBytes, .memoryRecommendedBytes, &container)
        try TelemetryNullEncoding.encode(workingSetRatioFraction, .workingSetRatioFraction, &container)
        try TelemetryNullEncoding.encode(workingSetHeadroomBytes, .workingSetHeadroomBytes, &container)
        try container.encode(availability, forKey: .availability)
    }
}

extension TelemetrySampleV1.Network {
    private enum Keys: String, CodingKey {
        case downloadBytesPerSecond, uploadBytesPerSecond, availability
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try TelemetryNullEncoding.encode(downloadBytesPerSecond, .downloadBytesPerSecond, &container)
        try TelemetryNullEncoding.encode(uploadBytesPerSecond, .uploadBytesPerSecond, &container)
        try container.encode(availability, forKey: .availability)
    }
}

extension TelemetrySampleV1.Disk {
    private enum Keys: String, CodingKey {
        case readBytesPerSecond, writeBytesPerSecond, capacityBytes, availableBytes
        case usedBytes, usedFraction, ioAvailability, capacityAvailability
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try TelemetryNullEncoding.encode(readBytesPerSecond, .readBytesPerSecond, &container)
        try TelemetryNullEncoding.encode(writeBytesPerSecond, .writeBytesPerSecond, &container)
        try TelemetryNullEncoding.encode(capacityBytes, .capacityBytes, &container)
        try TelemetryNullEncoding.encode(availableBytes, .availableBytes, &container)
        try TelemetryNullEncoding.encode(usedBytes, .usedBytes, &container)
        try TelemetryNullEncoding.encode(usedFraction, .usedFraction, &container)
        try container.encode(ioAvailability, forKey: .ioAvailability)
        try container.encode(capacityAvailability, forKey: .capacityAvailability)
    }
}

extension TelemetrySampleV1.Power {
    private enum Keys: String, CodingKey {
        case batteryFraction, externalPower, lowPowerModeEnabled, availability
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try TelemetryNullEncoding.encode(batteryFraction, .batteryFraction, &container)
        try TelemetryNullEncoding.encode(externalPower, .externalPower, &container)
        try container.encode(lowPowerModeEnabled, forKey: .lowPowerModeEnabled)
        try container.encode(availability, forKey: .availability)
    }
}

extension TelemetrySampleV1.System {
    private enum Keys: String, CodingKey {
        case overallPressureLevel, processCount
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(overallPressureLevel, forKey: .overallPressureLevel)
        try TelemetryNullEncoding.encode(processCount, .processCount, &container)
    }
}

extension TelemetrySampleV1.Observer {
    private enum Keys: String, CodingKey {
        case kind, cpuUsage, residentMemoryBytes, cpuAvailability, memoryAvailability
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(kind, forKey: .kind)
        try TelemetryNullEncoding.encode(cpuUsage, .cpuUsage, &container)
        try TelemetryNullEncoding.encode(residentMemoryBytes, .residentMemoryBytes, &container)
        try container.encode(cpuAvailability, forKey: .cpuAvailability)
        try container.encode(memoryAvailability, forKey: .memoryAvailability)
    }
}

extension LimitingResourceV1 {
    private enum Keys: String, CodingKey {
        case resource, level, valueFraction
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(resource, forKey: .resource)
        try container.encode(level, forKey: .level)
        try TelemetryNullEncoding.encode(valueFraction, .valueFraction, &container)
    }
}

extension StatusDocumentV1 {
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaURL, forKey: .schemaURL)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(document, forKey: .document)
        try container.encode(searoomVersion, forKey: .searoomVersion)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(source, forKey: .source)
        try container.encode(overallPressureLevel, forKey: .overallPressureLevel)
        try container.encode(limitingResources, forKey: .limitingResources)
        try container.encode(derived, forKey: .derived)
        try TelemetryNullEncoding.encode(sustained, .sustained, &container)
        try container.encode(historyContext, forKey: .historyContext)
        try container.encode(sample, forKey: .sample)
    }
}

extension StatusDocumentV1.HistoryContext {
    private enum Keys: String, CodingKey {
        case lastTimestamp, lagSeconds, approximateLagSeconds
        case usableForSustained, unusableReason
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try TelemetryNullEncoding.encode(lastTimestamp, .lastTimestamp, &container)
        try TelemetryNullEncoding.encode(lagSeconds, .lagSeconds, &container)
        try container.encode(approximateLagSeconds, forKey: .approximateLagSeconds)
        try container.encode(usableForSustained, forKey: .usableForSustained)
        try TelemetryNullEncoding.encode(unusableReason, .unusableReason, &container)
    }
}

extension StatusDocumentV1.Derived {
    private enum Keys: String, CodingKey {
        case memoryUsedFraction, memoryCompressedFraction, gpuWorkingSetHeadroomBytes
        case diskUsedBytes, diskUsedFraction, powerStateLabel, swapActivityState
        case fanState, observerState
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try TelemetryNullEncoding.encode(memoryUsedFraction, .memoryUsedFraction, &container)
        try TelemetryNullEncoding.encode(memoryCompressedFraction, .memoryCompressedFraction, &container)
        try TelemetryNullEncoding.encode(gpuWorkingSetHeadroomBytes, .gpuWorkingSetHeadroomBytes, &container)
        try TelemetryNullEncoding.encode(diskUsedBytes, .diskUsedBytes, &container)
        try TelemetryNullEncoding.encode(diskUsedFraction, .diskUsedFraction, &container)
        try container.encode(powerStateLabel, forKey: .powerStateLabel)
        try container.encode(swapActivityState, forKey: .swapActivityState)
        try container.encode(fanState, forKey: .fanState)
        try container.encode(observerState, forKey: .observerState)
    }
}

extension HistoryDocumentV1 {
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaURL, forKey: .schemaURL)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(document, forKey: .document)
        try container.encode(searoomVersion, forKey: .searoomVersion)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(source, forKey: .source)
        try container.encode(archivePath, forKey: .archivePath)
        try container.encode(approximateLagSeconds, forKey: .approximateLagSeconds)
        try container.encode(sampleCount, forKey: .sampleCount)
        try TelemetryNullEncoding.encode(sustainedBeforeFiltering, .sustainedBeforeFiltering, &container)
        try container.encode(samples, forKey: .samples)
    }
}

extension CapabilityV1 {
    private enum Keys: String, CodingKey {
        case group, availability, source, refreshCadenceSeconds, notes
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(group, forKey: .group)
        try container.encode(availability, forKey: .availability)
        try container.encode(source, forKey: .source)
        try TelemetryNullEncoding.encode(refreshCadenceSeconds, .refreshCadenceSeconds, &container)
        try TelemetryNullEncoding.encode(notes, .notes, &container)
    }
}

extension MetricDefinitionV1 {
    private enum Keys: String, CodingKey {
        case id, jsonPath, displayName, unit, range, nullable, source, sourceStability
        case refreshCadence, refreshCadenceSeconds, derivation, thresholds
        case firstSampleBehavior, rollbackBehavior, limitations, interpretationNotes
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(id, forKey: .id)
        try container.encode(jsonPath, forKey: .jsonPath)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(unit, forKey: .unit)
        try container.encode(range, forKey: .range)
        try container.encode(nullable, forKey: .nullable)
        try container.encode(source, forKey: .source)
        try container.encode(sourceStability, forKey: .sourceStability)
        try container.encode(refreshCadence, forKey: .refreshCadence)
        try TelemetryNullEncoding.encode(refreshCadenceSeconds, .refreshCadenceSeconds, &container)
        try TelemetryNullEncoding.encode(derivation, .derivation, &container)
        try TelemetryNullEncoding.encode(thresholds, .thresholds, &container)
        try container.encode(firstSampleBehavior, forKey: .firstSampleBehavior)
        try container.encode(rollbackBehavior, forKey: .rollbackBehavior)
        try container.encode(limitations, forKey: .limitations)
        try container.encode(interpretationNotes, forKey: .interpretationNotes)
    }
}

extension CLICommandCatalog.Argument {
    private enum Keys: String, CodingKey {
        case name, kind, required, defaultValue, validValues
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encode(required, forKey: .required)
        try TelemetryNullEncoding.encode(defaultValue, .defaultValue, &container)
        try TelemetryNullEncoding.encode(validValues, .validValues, &container)
    }
}
