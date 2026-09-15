import Darwin
import Foundation

/// One ranked process. `cpuUsage` is process CPU seconds per wall second, the
/// same quantity as the Searoom observer metric: a process working on several
/// cores legitimately exceeds 1.0, so it is presented with
/// `MetricFormat.unboundedPercent` rather than clamped like system usage.
struct RankedProcess: Equatable, Sendable {
    let pid: Int32
    let name: String
    let cpuUsage: Double
    let residentBytes: UInt64
}

/// The top few processes by CPU and by resident memory at the last scan.
///
/// Deliberately outside `SystemSample`: process names must never enter
/// persisted history, settings, or CLI documents, so this travels beside the
/// sample and lives only in `AppModel` display state.
struct ProcessRanking: Equatable, Sendable {
    /// A candidate measurement without its display name. Names are resolved
    /// only for entries that survive ranking, so a full system scan performs
    /// no string work.
    struct Candidate: Equatable, Sendable {
        let pid: Int32
        let cpuUsage: Double
        let residentBytes: UInt64
    }

    /// Five per column, so the full-width card lists at most ten processes.
    static let maximumCount = 5
    /// Before the first scan there is no data at all; memory arrives with the
    /// first read and CPU rates need one more, so the placeholder warms up.
    static let empty = ProcessRanking(byCPU: [], byMemory: [], availability: .warmingUp)

    let byCPU: [RankedProcess]
    let byMemory: [RankedProcess]
    let availability: ReadingAvailability

    /// Pure ranking shared by the collector, the self-test, and XCTest. The
    /// CPU list keeps measurable consumers only, ties keep input order, and
    /// both lists are capped at `limit`.
    static func rankedPIDs(
        in pool: [Candidate],
        limit: Int = maximumCount
    ) -> (cpu: [Int32], memory: [Int32]) {
        let byCPU = pool
            .enumerated()
            .filter { $0.element.cpuUsage > 0 }
            .sorted {
                $0.element.cpuUsage == $1.element.cpuUsage
                    ? $0.offset < $1.offset
                    : $0.element.cpuUsage > $1.element.cpuUsage
            }
            .prefix(limit)
            .map(\.element.pid)
        let byMemory = pool
            .enumerated()
            .sorted {
                $0.element.residentBytes == $1.element.residentBytes
                    ? $0.offset < $1.offset
                    : $0.element.residentBytes > $1.element.residentBytes
            }
            .prefix(limit)
            .map(\.element.pid)
        return (cpu: byCPU, memory: byMemory)
    }
}

/// Ranks processes by CPU and resident memory using only public libproc calls,
/// unprivileged, with no subprocess. One `proc_pidinfo` syscall per process on
/// a five-second deadline; names are read for the surviving entries only.
final class TopProcessCollector {
    private static let cadence = Duration.seconds(5)
    /// `proc_pidpath` documents 4 * MAXPATHLEN (4096) as its buffer maximum.
    private static let pathBufferSize = 4_096
    /// `proc_name` returns at most 2 * MAXCOMLEN (32) bytes.
    private static let nameBufferSize = 32

    private var baselines: [Int32: Double] = [:]
    private var previousInstant: ContinuousClock.Instant?
    private let clock = ContinuousClock()
    private var cachedRanking = ProcessRanking.empty
    private var nextRead: ContinuousClock.Instant?

    func read() -> ProcessRanking {
        let now = clock.now
        guard nextRead.map({ now >= $0 }) ?? true else { return cachedRanking }
        nextRead = now.advanced(by: Self.cadence)

        let hadBaseline = previousInstant != nil
        var elapsed: Double = 0
        if let previousInstant {
            let delta = previousInstant.duration(to: now)
            elapsed = Double(delta.components.seconds) + Double(delta.components.attoseconds) / 1e18
        }

        let pidCount = proc_listallpids(nil, 0)
        guard pidCount > 0 else {
            // A failed scan keeps the last successful baselines untouched, so
            // the next recovery read spans the whole gap, the same convention
            // as the disk counters.
            cachedRanking = ProcessRanking(byCPU: [], byMemory: [], availability: .unavailable)
            return cachedRanking
        }

        let candidates = scan(pidCount: pidCount, hadBaseline: hadBaseline, elapsed: elapsed)
        previousInstant = now
        let ranked = ProcessRanking.rankedPIDs(in: candidates)
        cachedRanking = ProcessRanking(
            byCPU: named(ranked.cpu, from: candidates),
            byMemory: named(ranked.memory, from: candidates),
            availability: hadBaseline ? .available : .warmingUp
        )
        return cachedRanking
    }

    /// One scan of the process table. Baselines are rebuilt into a fresh
    /// dictionary each pass, which both installs the next counters and drops
    /// the entries of processes that have exited.
    private func scan(pidCount: Int32, hadBaseline: Bool, elapsed: Double) -> [ProcessRanking.Candidate] {
        var pids = [Int32](repeating: 0, count: Int(pidCount))
        let filled = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, pidCount)
        }
        guard filled > 0 else {
            cachedRanking = ProcessRanking(byCPU: [], byMemory: [], availability: .unavailable)
            return []
        }

        let filledCount = Int(filled)
        let ownPID = getpid()
        var nextBaselines = [Int32: Double](minimumCapacity: filledCount)
        var candidates: [ProcessRanking.Candidate] = []
        candidates.reserveCapacity(filledCount)
        for pid in pids[0..<filledCount] where pid > 0 && pid != ownPID {
            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            let result = withUnsafeMutableBytes(of: &info) { raw in
                proc_pidinfo(pid, PROC_PIDTASKINFO, 0, raw.baseAddress, size)
            }
            // Other-user processes can refuse the read; skip them rather than
            // fabricating a zero.
            guard result == size else { continue }

            let cpuSeconds = Double(info.pti_total_user + info.pti_total_system) / 1_000_000
            var usage = 0.0
            if hadBaseline, elapsed > 0, let previous = baselines[pid] {
                // Counter rollback, usually a recycled PID, yields zero for
                // that interval like every other counter here.
                usage = cpuSeconds >= previous ? (cpuSeconds - previous) / elapsed : 0
            }
            nextBaselines[pid] = cpuSeconds
            candidates.append(ProcessRanking.Candidate(
                pid: pid,
                cpuUsage: usage,
                residentBytes: info.pti_resident_size
            ))
        }
        baselines = nextBaselines
        return candidates
    }

    private func named(_ pids: [Int32], from pool: [ProcessRanking.Candidate]) -> [RankedProcess] {
        pids.compactMap { pid in
            pool.first { $0.pid == pid }.map { candidate in
                RankedProcess(
                    pid: pid,
                    name: Self.processName(pid),
                    cpuUsage: candidate.cpuUsage,
                    residentBytes: candidate.residentBytes
                )
            }
        }
    }

    private static func processName(_ pid: Int32) -> String {
        var path = [CChar](repeating: 0, count: pathBufferSize)
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
            let text = cString(path)
            guard !text.isEmpty else { return "PID \(pid)" }
            return (text as NSString).lastPathComponent
        }
        var short = [CChar](repeating: 0, count: nameBufferSize)
        if proc_name(pid, &short, UInt32(short.count)) > 0 {
            let text = cString(short)
            return text.isEmpty ? "PID \(pid)" : text
        }
        return "PID \(pid)"
    }

    /// The array-based `String(cString:)` is deprecated in Swift 6; decode the
    /// bytes up to the terminator instead.
    private static func cString(_ buffer: [CChar]) -> String {
        let length = buffer.firstIndex(of: 0) ?? buffer.count
        return String(decoding: buffer[..<length].map(UInt8.init), as: UTF8.self)
    }
}
