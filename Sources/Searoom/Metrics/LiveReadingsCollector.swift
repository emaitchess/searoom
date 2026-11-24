import CSearoomSensors
import Darwin
import Foundation
import IOKit

/// One logical CPU. `kind` is the kernel's own name for the core's performance
/// level, lowercased, and nil when the mapping cannot be confirmed. Usage is
/// nil until a baseline exists and whenever the core reported no elapsed ticks.
struct CoreReading: Equatable, Sendable {
    let index: Int
    let kind: String?
    let usage: Double?
}

/// Readings that live CLI documents carry and the app does not. They sit beside
/// `SystemSample` the way `ProcessRanking` does: nothing here is persisted, and
/// the menu-bar app never pays for them.
struct LiveReadings: Equatable, Sendable {
    let cores: [CoreReading]
    let coresAvailability: ReadingAvailability
    let systemWatts: Double?
    let gpuTemperatureCelsius: Double?

    static let unavailable = LiveReadings(
        cores: [],
        coresAvailability: .unavailable,
        systemWatts: nil,
        gpuTemperatureCelsius: nil
    )

    var systemWattsAvailability: ReadingAvailability {
        systemWatts == nil ? .unavailable : .available
    }

    var gpuTemperatureAvailability: ReadingAvailability {
        gpuTemperatureCelsius == nil ? .unavailable : .available
    }
}

final class LiveReadingsCollector {
    private let cores = CoreCollector()
    private let clock = ContinuousClock()
    private var nextTemperatureReading: ContinuousClock.Instant?
    private var cachedGPUTemperature: Double?
    // No CPU sensor family is read. On an M4 its keys are one sensor at fixed
    // offsets plus values that jump 20 degrees above their neighbours while
    // idle, apparently held peaks, so neither their mean nor their maximum is a
    // temperature.

    /// Cores and power are read every time, which is one Mach call and one SMC
    /// key. The GPU sensors are dozens of keys, so they keep the six-second thermal
    /// cadence.
    func read() -> LiveReadings {
        let now = clock.now
        if nextTemperatureReading.map({ now >= $0 }) ?? true {
            var celsius = 0.0
            cachedGPUTemperature = SRReadGPUTemperature(&celsius) ? celsius : nil
            nextTemperatureReading = now.advanced(by: .seconds(6))
        }
        var watts = 0.0
        let systemWatts = SRReadSystemPower(&watts) ? watts : nil
        let coreReading = cores.read()
        return LiveReadings(
            cores: coreReading.cores,
            coresAvailability: coreReading.availability,
            systemWatts: systemWatts,
            gpuTemperatureCelsius: cachedGPUTemperature
        )
    }

}

/// Per-core busy time, as a delta of Mach processor ticks.
final class CoreCollector {
    struct Reading: Equatable {
        let cores: [CoreReading]
        let availability: ReadingAvailability
    }

    struct Ticks: Equatable {
        let user: UInt32
        let system: UInt32
        let nice: UInt32
        let idle: UInt32
    }

    private var previous: [Ticks]?
    // Which core is which never changes while a process runs, so the device
    // tree is read once, and only when somebody asks for cores.
    private var kinds: [String?]?

    func read() -> Reading {
        guard let current = Self.readTicks(), !current.isEmpty else {
            previous = nil
            return Reading(cores: [], availability: .unavailable)
        }
        let kinds = kinds ?? Self.readKinds(coreCount: current.count)
        self.kinds = kinds
        defer { previous = current }
        return Self.reading(current: current, previous: previous, kinds: kinds)
    }

    static func reading(current: [Ticks], previous: [Ticks]?, kinds: [String?]) -> Reading {
        // A changed core count leaves nothing to compare, so it rebaselines.
        let baseline = previous.flatMap { $0.count == current.count ? $0 : nil }
        let cores = current.indices.map { index in
            CoreReading(
                index: index,
                kind: kinds.indices.contains(index) ? kinds[index] : nil,
                usage: baseline.flatMap { usage(from: $0[index], to: current[index]) }
            )
        }
        return Reading(cores: cores, availability: baseline == nil ? .warmingUp : .available)
    }

    static func usage(from previous: Ticks, to current: Ticks) -> Double? {
        // The kernel's counters are 32-bit and wrap, so the deltas wrap too.
        let user = UInt64(current.user &- previous.user)
        let system = UInt64(current.system &- previous.system)
        let nice = UInt64(current.nice &- previous.nice)
        let idle = UInt64(current.idle &- previous.idle)
        let busy = user + system + nice
        let total = busy + idle
        // No elapsed ticks means nothing was measured, which is not zero.
        guard total > 0 else { return nil }
        return min(1, Double(busy) / Double(total))
    }

    private static func readTicks() -> [Ticks]? {
        var processorCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        guard host_processor_info(
            host,
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &info,
            &infoCount
        ) == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: info)),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            )
        }
        let states = Int(CPU_STATE_MAX)
        guard Int(infoCount) >= Int(processorCount) * states else { return nil }
        return (0..<Int(processorCount)).map { core in
            func ticks(_ state: Int32) -> UInt32 {
                UInt32(bitPattern: info[core * states + Int(state)])
            }
            return Ticks(
                user: ticks(CPU_STATE_USER),
                system: ticks(CPU_STATE_SYSTEM),
                nice: ticks(CPU_STATE_NICE),
                idle: ticks(CPU_STATE_IDLE)
            )
        }
    }

    // MARK: - Core kinds

    struct PerformanceLevel: Equatable {
        let name: String
        let coreCount: Int
    }

    private static func readKinds(coreCount: Int) -> [String?] {
        kinds(
            levels: readPerformanceLevels(),
            clusterTypes: readClusterTypes(),
            coreCount: coreCount
        )
    }

    /// Joins two sources and reports nothing when they disagree. The device
    /// tree says which logical CPU belongs to which cluster type; the kernel's
    /// `hw.perflevel` names the levels, fastest first. Cluster letters are not
    /// level names: on an M5 Pro the `P` clusters are the level the kernel calls
    /// Super and the `M` clusters are the one it calls Performance. Verified
    /// there by watching which CPUs background and interactive work landed on.
    static func kinds(
        levels: [PerformanceLevel],
        clusterTypes: [Int: String],
        coreCount: Int
    ) -> [String?] {
        let unknown = [String?](repeating: nil, count: coreCount)
        guard !levels.isEmpty,
              clusterTypes.count == coreCount,
              (0..<coreCount).allSatisfy({ clusterTypes[$0] != nil })
        else { return unknown }

        let fastestFirst = ["P", "M", "E"]
        var counts: [String: Int] = [:]
        for type in clusterTypes.values { counts[type, default: 0] += 1 }
        guard counts.keys.allSatisfy(fastestFirst.contains) else { return unknown }
        let present = fastestFirst.filter { counts[$0] != nil }
        guard present.count == levels.count else { return unknown }

        var names: [String: String] = [:]
        for (type, level) in zip(present, levels) {
            guard counts[type] == level.coreCount else { return unknown }
            names[type] = level.name
        }
        return (0..<coreCount).map { clusterTypes[$0].flatMap { names[$0] } }
    }

    private static func readPerformanceLevels() -> [PerformanceLevel] {
        var levelCount: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.nperflevels", &levelCount, &size, nil, 0) == 0,
              (1...8).contains(levelCount)
        else { return [] }
        var levels: [PerformanceLevel] = []
        for level in 0..<Int(levelCount) {
            var cores: Int32 = 0
            var coresSize = MemoryLayout<Int32>.size
            var name = [CChar](repeating: 0, count: 64)
            var nameSize = name.count
            guard sysctlbyname("hw.perflevel\(level).logicalcpu", &cores, &coresSize, nil, 0) == 0,
                  sysctlbyname("hw.perflevel\(level).name", &name, &nameSize, nil, 0) == 0,
                  cores > 0
            else { return [] }
            let bytes = name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let label = String(decoding: bytes, as: UTF8.self).lowercased()
            guard !label.isEmpty else { return [] }
            levels.append(PerformanceLevel(name: label, coreCount: Int(cores)))
        }
        return levels
    }

    // Undocumented and read-only. Node names skip numbers where cores are
    // fused off (an M5 Pro has no cpu5 or cpu11), so only `logical-cpu-id`
    // lines up with the kernel's processor order.
    private static func readClusterTypes() -> [Int: String] {
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != 0 else { return [:] }
        defer { IOObjectRelease(cpus) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(cpus, "IODeviceTree", &iterator) == KERN_SUCCESS else {
            return [:]
        }
        defer { IOObjectRelease(iterator) }

        var types: [Int: String] = [:]
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            func property(_ name: String) -> Any? {
                IORegistryEntryCreateCFProperty(
                    entry,
                    name as CFString,
                    kCFAllocatorDefault,
                    0
                )?.takeRetainedValue()
            }
            guard let index = (property("logical-cpu-id") as? NSNumber)?.intValue,
                  let data = property("cluster-type") as? Data
            else { continue }
            let type = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
            guard !type.isEmpty else { continue }
            types[index] = type
        }
        return types
    }
}
