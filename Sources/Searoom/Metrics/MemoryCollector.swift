import Darwin
import Foundation

final class MemoryCollector {
    private var previousSwapInPages: UInt64?
    private var previousSwapOutPages: UInt64?
    private var previousSwapTime: ContinuousClock.Instant?
    private let clock = ContinuousClock()
    private let total = ProcessInfo.processInfo.physicalMemory
    private let pageBytes: UInt64 = {
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        return UInt64(pageSize)
    }()

    struct Reading {
        let total: UInt64
        let used: UInt64
        let available: UInt64
        let cached: UInt64
        let swapUsed: UInt64
        let swapInPerSecond: Double
        let swapOutPerSecond: Double
        let pressure: Double
        let pressureLevel: PressureLevel
    }

    func read() -> Reading {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return Reading(
                total: total,
                used: 0,
                available: total,
                cached: 0,
                swapUsed: readSwapUsed(),
                swapInPerSecond: 0,
                swapOutPerSecond: 0,
                pressure: 0,
                pressureLevel: .unavailable
            )
        }

        let active = UInt64(statistics.active_count) * pageBytes
        let wired = UInt64(statistics.wire_count) * pageBytes
        let compressed = UInt64(statistics.compressor_page_count) * pageBytes
        let inactive = UInt64(statistics.inactive_count) * pageBytes
        let purgeable = UInt64(statistics.purgeable_count) * pageBytes
        let speculative = UInt64(statistics.speculative_count) * pageBytes

        // Active + wired + compressed is the non-readily-reclaimable working set.
        // Inactive, purgeable, and speculative pages are reported as reclaimable memory.
        let used = min(total, active + wired + compressed)
        let available = total - used
        let cached = min(available, inactive + purgeable + speculative)
        let swapUsed = readSwapUsed()
        let swapRates = readSwapRates(
            swapInPages: UInt64(statistics.swapins),
            swapOutPages: UInt64(statistics.swapouts),
            pageBytes: pageBytes
        )
        let utilization = total > 0 ? Double(used) / Double(total) : 0

        let systemLevel = readSystemPressureLevel()
        let derivedLevel = PressureLevel.from(utilization: utilization)
        let level = max(systemLevel ?? .unavailable, derivedLevel)
        let floor: Double = switch level {
        case .nominal, .unavailable: 0
        case .elevated: 0.72
        case .constrained: 0.86
        case .critical: 0.96
        }

        return Reading(
            total: total,
            used: used,
            available: available,
            cached: cached,
            swapUsed: swapUsed,
            swapInPerSecond: swapRates.input,
            swapOutPerSecond: swapRates.output,
            pressure: min(1, max(utilization, floor)),
            pressureLevel: level
        )
    }

    private func readSwapRates(
        swapInPages: UInt64,
        swapOutPages: UInt64,
        pageBytes: UInt64
    ) -> (input: Double, output: Double) {
        let now = clock.now
        defer {
            previousSwapInPages = swapInPages
            previousSwapOutPages = swapOutPages
            previousSwapTime = now
        }
        guard let previousSwapInPages,
              let previousSwapOutPages,
              let previousSwapTime else { return (0, 0) }

        let elapsed = previousSwapTime.duration(to: now)
        let duration = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        guard duration > 0 else { return (0, 0) }

        let inputPages = swapInPages >= previousSwapInPages
            ? swapInPages - previousSwapInPages
            : 0
        let outputPages = swapOutPages >= previousSwapOutPages
            ? swapOutPages - previousSwapOutPages
            : 0
        let input = Double(inputPages) * Double(pageBytes) / duration
        let output = Double(outputPages) * Double(pageBytes) / duration
        return (
            input.isFinite ? max(0, input) : 0,
            output.isFinite ? max(0, output) : 0
        )
    }

    private func readSystemPressureLevel() -> PressureLevel? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0 else {
            return nil
        }
        return switch value {
        case 1: PressureLevel.nominal
        case 2: PressureLevel.constrained
        case 4: PressureLevel.critical
        default: nil
        }
    }

    private func readSwapUsed() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }
}
