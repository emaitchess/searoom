import Darwin
import Foundation

final class CPUCollector {
    private var previousUsed: UInt64?
    private var previousTotal: UInt64?
    private let logicalCPUCount = max(1, ProcessInfo.processInfo.activeProcessorCount)

    struct Reading {
        let usage: Double
        let pressure: Double
        let pressureLevel: PressureLevel
        let loadAverage1m: Double
        let logicalCPUCount: Int
    }

    func read() -> Reading {
        let usage = readUsage()
        var averages = (0.0, 0.0, 0.0)
        let count = withUnsafeMutablePointer(to: &averages) { pointer in
            pointer.withMemoryRebound(to: Double.self, capacity: 3) {
                getloadavg($0, 3)
            }
        }
        let loadAverage = count > 0 ? averages.0 : 0

        // macOS does not expose Linux-style CPU PSI. This saturation signal combines
        // active CPU time with the normalized run queue and is explicitly labelled
        // as a derived metric in the UI and documentation.
        let normalizedLoad = min(1, loadAverage / Double(logicalCPUCount))
        let pressure = min(1, max(usage, normalizedLoad))

        return Reading(
            usage: usage,
            pressure: pressure,
            pressureLevel: PressureLevel.from(utilization: pressure),
            loadAverage1m: loadAverage,
            logicalCPUCount: logicalCPUCount
        )
    }

    private func readUsage() -> Double {
        var statistics = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        let ticks = withUnsafePointer(to: statistics.cpu_ticks) { pointer in
            pointer.withMemoryRebound(to: UInt32.self, capacity: Int(CPU_STATE_MAX)) {
                (user: UInt64($0[Int(CPU_STATE_USER)]),
                 system: UInt64($0[Int(CPU_STATE_SYSTEM)]),
                 nice: UInt64($0[Int(CPU_STATE_NICE)]),
                 idle: UInt64($0[Int(CPU_STATE_IDLE)]))
            }
        }
        let used = ticks.user + ticks.system + ticks.nice
        let total = used + ticks.idle

        defer {
            previousUsed = used
            previousTotal = total
        }
        guard let previousUsed, let previousTotal, total > previousTotal else { return 0 }
        return min(1, Double(used - previousUsed) / Double(total - previousTotal))
    }
}
