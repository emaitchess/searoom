import CSearoomSensors
import Darwin
import Foundation
import IOKit
import IOKit.ps
import Metal

final class ThermalCollector {
    static func sensorDecoderSelfTest() -> Bool {
        SRRunSensorDecoderSelfTest()
    }

    func read() -> (temperature: Double?, pressureLevel: PressureLevel, fans: [FanSample]) {
        var temperature = 0.0
        let measuredTemperature = SRReadTemperature(&temperature) ? temperature : nil

        let level: PressureLevel = switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .elevated
        case .serious: .constrained
        case .critical: .critical
        @unknown default: .unavailable
        }

        var fanSpeeds = [Double](repeating: 0, count: 10)
        let fanCount = Int(SRReadFanSpeeds(&fanSpeeds, Int32(fanSpeeds.count)))
        let fans = fanSpeeds.prefix(fanCount).enumerated().map {
            FanSample(name: "FAN \($0.offset + 1)", rpm: $0.element)
        }
        return (measuredTemperature, level, fans)
    }
}

final class GPUCollector {
    private let utilizationKeys = [
        "Device Utilization %",
        "Renderer Utilization %",
        "GPU Activity(%)",
        "GPU Activity %",
        "GPU Core Utilization",
        "GPU Utilization %"
    ]
    private var services: [io_registry_entry_t] = []
    private let clock = ContinuousClock()
    private var nextDiscovery: ContinuousClock.Instant?
    private let physicalMemory = ProcessInfo.processInfo.physicalMemory

    // The working-set budget comes from the public Metal API rather than the
    // undocumented "Recommended Max Working Set Size" registry key, which is
    // absent on Apple Silicon (verified on an M5 Pro's AGXAccelerator). Resolved
    // lazily on the collector's serial queue; a nil or zero budget leaves the
    // working-set ratio unavailable without affecting GPU utilization.
    private lazy var recommendedWorkingSetBytes: UInt64? = {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let budget = device.recommendedMaxWorkingSetSize
        return budget > 0 ? budget : nil
    }()

    deinit { releaseServices() }

    func read() -> (
        usage: Double?,
        pressure: Double?,
        level: PressureLevel,
        memoryUsedBytes: UInt64?,
        memoryRecommendedBytes: UInt64?,
        memoryPressure: Double?
    ) {
        if services.isEmpty, nextDiscovery.map({ clock.now >= $0 }) ?? true {
            discoverServices()
        }
        guard !services.isEmpty else { return (nil, nil, .unavailable, nil, nil, nil) }

        var maximumUsage: Double?
        var maximumUsedMemory: UInt64?
        for service in services {
            guard let statistics = dictionaryProperty(
                named: "PerformanceStatistics",
                service: service
            ) else { continue }
            for key in utilizationKeys {
                guard let number = statistics[key] as? NSNumber else { continue }
                let raw = number.doubleValue
                let value = raw > 1 ? raw / 100 : raw
                maximumUsage = max(maximumUsage ?? value, value)
            }
            if let used = Self.parseUsedSystemMemory(
                statistics,
                physicalMemory: physicalMemory
            ) {
                maximumUsedMemory = max(maximumUsedMemory ?? used, used)
            }
        }

        guard let usage = maximumUsage.map({ min(1, max(0, $0)) }) else {
            releaseServices()
            nextDiscovery = clock.now.advanced(by: .seconds(60))
            return (nil, nil, .unavailable, nil, nil, nil)
        }
        let memoryPressure = Self.workingSetRatio(
            used: maximumUsedMemory,
            recommended: recommendedWorkingSetBytes
        )
        let pressure = Self.combinedPressure(usage: usage, workingSetRatio: memoryPressure)
        return (
            usage,
            pressure,
            PressureLevel.from(utilization: pressure),
            maximumUsedMemory,
            recommendedWorkingSetBytes,
            memoryPressure
        )
    }

    // "In use system memory" is a read-only, undocumented IORegistry value that
    // Apple GPU drivers publish in bytes; verified on an Apple M5 Pro
    // (AGXAccelerator, macOS 27.0) reporting 631,635,968. Some non-Apple
    // drivers publish the same key in megabytes, so values that exceed
    // physical memory are rejected as unavailable rather than trusted.
    static func parseUsedSystemMemory(
        _ statistics: [String: Any],
        physicalMemory: UInt64
    ) -> UInt64? {
        guard let number = statistics["In use system memory"] as? NSNumber else { return nil }
        let used = number.uint64Value
        guard used > 0, used <= physicalMemory else { return nil }
        return used
    }

    static func workingSetRatio(used: UInt64?, recommended: UInt64?) -> Double? {
        guard let used, let recommended, recommended > 0 else { return nil }
        return min(1, Double(used) / Double(recommended))
    }

    // GPU pressure combines utilization with the Metal-recommended working-set
    // ratio, mirroring how CPU pressure combines usage with normalized load.
    // It is a derived signal, not an Apple pressure API.
    static func combinedPressure(usage: Double, workingSetRatio: Double?) -> Double {
        min(1, max(usage, workingSetRatio ?? 0))
    }

    private func discoverServices() {
        var discovered: [io_registry_entry_t] = []
        var registryIDs = Set<UInt64>()
        for className in ["IOAccelerator", "AGXAccelerator", "AppleAGXAccelerator"] {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(
                kIOMainPortDefault,
                IOServiceMatching(className),
                &iterator
            ) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }

            while case let service = IOIteratorNext(iterator), service != 0 {
                var registryID: UInt64 = 0
                if IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS,
                   registryIDs.insert(registryID).inserted {
                    discovered.append(service)
                } else {
                    IOObjectRelease(service)
                }
            }
        }
        services = discovered
        if services.isEmpty { nextDiscovery = clock.now.advanced(by: .seconds(60)) }
    }

    private func dictionaryProperty(named name: String, service: io_registry_entry_t) -> [String: Any]? {
        IORegistryEntryCreateCFProperty(
            service,
            name as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? [String: Any]
    }

    private func releaseServices() {
        for service in services { IOObjectRelease(service) }
        services.removeAll(keepingCapacity: true)
    }
}

final class BatteryCollector {
    private var cached: (percent: Double?, externalPower: Bool?, temperature: Double?) = (nil, nil, nil)
    private let clock = ContinuousClock()
    private var nextRead: ContinuousClock.Instant?

    func read() -> (percent: Double?, externalPower: Bool?, temperature: Double?) {
        let now = clock.now
        guard nextRead.map({ now >= $0 }) ?? true else { return cached }
        nextRead = now.advanced(by: .seconds(30))

        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return cached }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                as? [String: Any] else { continue }
            guard (description[kIOPSTransportTypeKey] as? String) == kIOPSInternalType else { continue }

            let current = (description[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue
            let maximum = (description[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue
            let percent: Double? = if let current, let maximum, maximum > 0 { current / maximum } else { nil }
            let state = description[kIOPSPowerSourceStateKey] as? String
            let rawPublishedTemperature = (description[kIOPSTemperatureKey] as? NSNumber)?.doubleValue
            let publishedTemperature = rawPublishedTemperature.flatMap(Self.normalizeTemperature)
            let temperature = publishedTemperature ?? Self.readRegistryTemperature()
            cached = (percent, state.map { $0 == kIOPSACPowerValue }, temperature)
            return cached
        }
        return cached
    }

    static func normalizeTemperature(_ raw: Double) -> Double? {
        guard raw.isFinite else { return nil }
        // IOPS documents this key in Celsius, while AppleSmartBattery registry
        // implementations also publish hundredths of a degree Celsius. For
        // example, 2759 represents 27.59°C, not 275.9 K.
        let celsius = (-40...100).contains(raw) ? raw : raw / 100
        return (-40...100).contains(celsius) ? celsius : nil
    }

    private static func readRegistryTemperature() -> Double? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        if let temperature = temperatureProperty(on: service).flatMap(normalizeTemperature) {
            return temperature
        }

        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(
            service,
            kIOServicePlane,
            IOOptionBits(kIORegistryIterateRecursively),
            &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            if let temperature = temperatureProperty(on: entry).flatMap(normalizeTemperature) {
                return temperature
            }
        }
        return nil
    }

    private static func temperatureProperty(on entry: io_registry_entry_t) -> Double? {
        if let number = IORegistryEntryCreateCFProperty(
            entry,
            kIOPSTemperatureKey as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? NSNumber {
            return number.doubleValue
        }
        guard let batteryData = IORegistryEntryCreateCFProperty(
            entry,
            "BatteryData" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? [String: Any] else { return nil }
        return (batteryData[kIOPSTemperatureKey] as? NSNumber)?.doubleValue
    }
}

final class ProcessCollector {
    private var previousCPUTime: Double?
    private var previousTime: ContinuousClock.Instant?
    private let clock = ContinuousClock()
    private var cachedProcessCount = 0
    private var nextProcessCountRead: ContinuousClock.Instant?

    func read() -> (cpu: Double, memory: UInt64, processCount: Int) {
        var usage = rusage()
        let result = getrusage(RUSAGE_SELF, &usage)
        let totalCPU = result == 0
            ? Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
            : 0

        let now = clock.now
        var cpu = 0.0
        if let previousCPUTime, let previousTime {
            let elapsed = previousTime.duration(to: now)
            let duration = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            if duration > 0 {
                cpu = max(0, (totalCPU - previousCPUTime) / duration)
            }
        }
        previousCPUTime = totalCPU
        previousTime = now

        var taskInfo = mach_task_basic_info_data_t()
        var taskInfoCount = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let memoryResult = withUnsafeMutablePointer(to: &taskInfo) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(taskInfoCount)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &taskInfoCount)
            }
        }
        let memory = memoryResult == KERN_SUCCESS ? UInt64(taskInfo.resident_size) : 0
        if nextProcessCountRead.map({ now >= $0 }) ?? true {
            cachedProcessCount = max(0, Int(proc_listallpids(nil, 0)))
            nextProcessCountRead = now.advanced(by: .seconds(60))
        }
        return (cpu, memory, cachedProcessCount)
    }
}
