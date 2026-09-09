import Foundation

/// Why a stored number is what it is. macOS telemetry collapses three very
/// different states into numeric zero — a valid idle reading, the first
/// baseline for a delta counter, and a system-call failure — and an
/// agent-facing API cannot ask consumers to guess between them.
enum ReadingAvailability: String, Codable, Equatable, Sendable, CaseIterable {
    /// Measured successfully. Zero means zero.
    case available
    /// The source has no baseline yet, so a rate or usage reading is
    /// deliberately zero until the next sample.
    case warmingUp
    /// The system call, registry query, or sensor read failed. The numeric
    /// value is a placeholder and must not be interpreted.
    case unavailable
    /// The sample predates availability metadata, so the state is unknown.
    /// Persisted archives from before this field existed decode this way.
    case legacyUnknown
}

/// Per-source-domain availability for one sample. Domains match the plan's
/// coverage table; the struct is embedded in `SystemSample` and decodes as
/// all-`legacyUnknown` when absent so version-1 archives keep loading.
struct SampleAvailability: Codable, Equatable, Sendable {
    var cpuUsageLoad: ReadingAvailability
    var vmStatistics: ReadingAvailability
    var swapUsage: ReadingAvailability
    var swapIO: ReadingAvailability
    var compressionIO: ReadingAvailability
    var networkIO: ReadingAvailability
    var diskIO: ReadingAvailability
    var diskCapacity: ReadingAvailability
    var temperature: ReadingAvailability
    var fans: ReadingAvailability
    var gpu: ReadingAvailability
    var battery: ReadingAvailability
    var processCPU: ReadingAvailability
    var processMemory: ReadingAvailability
    var processCount: ReadingAvailability

    static let legacyUnknown = SampleAvailability(
        cpuUsageLoad: .legacyUnknown,
        vmStatistics: .legacyUnknown,
        swapUsage: .legacyUnknown,
        swapIO: .legacyUnknown,
        compressionIO: .legacyUnknown,
        networkIO: .legacyUnknown,
        diskIO: .legacyUnknown,
        diskCapacity: .legacyUnknown,
        temperature: .legacyUnknown,
        fans: .legacyUnknown,
        gpu: .legacyUnknown,
        battery: .legacyUnknown,
        processCPU: .legacyUnknown,
        processMemory: .legacyUnknown,
        processCount: .legacyUnknown
    )

    init(
        cpuUsageLoad: ReadingAvailability,
        vmStatistics: ReadingAvailability,
        swapUsage: ReadingAvailability,
        swapIO: ReadingAvailability,
        compressionIO: ReadingAvailability,
        networkIO: ReadingAvailability,
        diskIO: ReadingAvailability,
        diskCapacity: ReadingAvailability,
        temperature: ReadingAvailability,
        fans: ReadingAvailability,
        gpu: ReadingAvailability,
        battery: ReadingAvailability,
        processCPU: ReadingAvailability,
        processMemory: ReadingAvailability,
        processCount: ReadingAvailability
    ) {
        self.cpuUsageLoad = cpuUsageLoad
        self.vmStatistics = vmStatistics
        self.swapUsage = swapUsage
        self.swapIO = swapIO
        self.compressionIO = compressionIO
        self.networkIO = networkIO
        self.diskIO = diskIO
        self.diskCapacity = diskCapacity
        self.temperature = temperature
        self.fans = fans
        self.gpu = gpu
        self.battery = battery
        self.processCPU = processCPU
        self.processMemory = processMemory
        self.processCount = processCount
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func decode(_ key: CodingKeys) throws -> ReadingAvailability {
            try values.decodeIfPresent(ReadingAvailability.self, forKey: key) ?? .legacyUnknown
        }
        cpuUsageLoad = try decode(.cpuUsageLoad)
        vmStatistics = try decode(.vmStatistics)
        swapUsage = try decode(.swapUsage)
        swapIO = try decode(.swapIO)
        compressionIO = try decode(.compressionIO)
        networkIO = try decode(.networkIO)
        diskIO = try decode(.diskIO)
        diskCapacity = try decode(.diskCapacity)
        temperature = try decode(.temperature)
        fans = try decode(.fans)
        gpu = try decode(.gpu)
        battery = try decode(.battery)
        processCPU = try decode(.processCPU)
        processMemory = try decode(.processMemory)
        processCount = try decode(.processCount)
    }

    private enum CodingKeys: String, CodingKey {
        case cpuUsageLoad
        case vmStatistics
        case swapUsage
        case swapIO
        case compressionIO
        case networkIO
        case diskIO
        case diskCapacity
        case temperature
        case fans
        case gpu
        case battery
        case processCPU
        case processMemory
        case processCount
    }
}
