import Foundation
import XCTest
@testable import Searoom

final class CLISamplingTests: XCTestCase {
    /// Records every collection so warm-up behavior is observable without
    /// sleeping and without real system calls.
    private final class SpyCollector: CLIRunner.Sampling, @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [Bool] = []
        private var samples: [SystemSample]

        init(samples: [SystemSample] = []) {
            self.samples = samples
        }

        func collect(forceDiskCounterRefresh: Bool) -> SystemSample {
            lock.lock()
            defer { lock.unlock() }
            requests.append(forceDiskCounterRefresh)
            if samples.isEmpty {
                return SystemSample.placeholder
            }
            return samples.removeFirst()
        }

        var recordedRequests: [Bool] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }
    }

    private final class FakeWaiter: CLIRunner.Waiter, @unchecked Sendable {
        private let lock = NSLock()
        private var waits: [Double] = []

        func wait(seconds: Double) {
            lock.lock()
            defer { lock.unlock() }
            waits.append(seconds)
        }

        var recordedWaits: [Double] {
            lock.lock()
            defer { lock.unlock() }
            return waits
        }
    }

    private final class CapturingStdout: CLIRunner.Stdout, @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()

        func write(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            buffer.append(data)
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: buffer, as: UTF8.self)
        }

        var lines: [String] {
            text.split(separator: "\n").map(String.init)
        }
    }

    /// Scripted signals: the nth query returns the scripted result.
    private final class ScriptedSignals: CLIRunner.SignalMonitor, @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [Int32?]
        private var installed = false

        init(_ pending: [Int32?]) {
            self.pending = pending
        }

        func install() {
            lock.lock()
            defer { lock.unlock() }
            installed = true
        }

        var didInstall: Bool {
            lock.lock()
            defer { lock.unlock() }
            return installed
        }

        var interruptedSignal: Int32? {
            lock.lock()
            defer { lock.unlock() }
            guard pending.isEmpty == false else { return nil }
            return pending.removeFirst()
        }
    }

    private var workDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("searoom-sampling-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeEnvironment(
        collector: SpyCollector,
        waiter: FakeWaiter,
        signals: CLIRunner.SignalMonitor,
        stdout: CapturingStdout,
        interval: Double = 2
    ) -> CLIRunner.Environment {
        CLIRunner.Environment(
            stdout: stdout,
            waiter: waiter,
            signals: signals,
            collector: collector,
            version: CLIVersionInfo(searoomVersion: "test", buildNumber: "0", macosFloor: "14.0"),
            now: { Date(timeIntervalSinceReferenceDate: 1_000) }
        )
    }

    func testWatchDiscardsPrimingSampleAndForcesDiskBaselineOnce() {
        let collector = SpyCollector()
        let waiter = FakeWaiter()
        let stdout = CapturingStdout()
        let signals = ScriptedSignals([nil, nil])
        let environment = makeEnvironment(collector: collector, waiter: waiter, signals: signals, stdout: stdout)

        let exit = CLIRunner.run(.watch(interval: 2, count: 2), json: false, pretty: false, environment: environment)
        XCTAssertEqual(exit, 0)
        // One discarded priming sample plus two emitted ones.
        XCTAssertEqual(collector.recordedRequests, [false, true, false])
        // Monotonic deadlines: waits accumulate from the chained deadline
        // (start + k*interval), never from "now", so collection duration
        // cannot introduce drift.
        //
        // The waits are what is left of each deadline once collection has
        // taken its time, so they sit a hair under the nominal value by
        // design. A millisecond of tolerance was measuring how loaded the
        // machine was, and failed a release audit at 3.998865; what the test
        // has to establish is that the second wait chains to the second
        // deadline rather than restarting from now, and 4 against 2 is not a
        // distinction a wide tolerance can blur.
        XCTAssertEqual(waiter.recordedWaits.count, 2)
        XCTAssertEqual(waiter.recordedWaits[0], 2, accuracy: 0.05)
        XCTAssertEqual(waiter.recordedWaits[1], 4, accuracy: 0.05)
        XCTAssertGreaterThan(
            waiter.recordedWaits[1],
            3,
            "a wait restarted from now would be one interval, not two"
        )
        // Two complete JSON lines, one document each.
        XCTAssertEqual(stdout.lines.count, 2)
        for line in stdout.lines {
            let object = try! JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            XCTAssertEqual(object["document"] as? String, "sample")
        }
    }

    func testCountCountsEmittedSamplesNotThePrimingSample() {
        let collector = SpyCollector()
        let environment = makeEnvironment(
            collector: collector,
            waiter: FakeWaiter(),
            signals: ScriptedSignals([]),
            stdout: CapturingStdout()
        )
        XCTAssertEqual(CLIRunner.run(.watch(interval: 1, count: 3), json: false, pretty: false, environment: environment), 0)
        XCTAssertEqual(collector.recordedRequests.count, 4)
    }

    func testWatchWithNoCountRunsUntilSignalled() {
        let collector = SpyCollector()
        let stdout = CapturingStdout()
        // One emitted sample, then SIGINT.
        let signals = ScriptedSignals([nil, SIGINT])
        let environment = makeEnvironment(collector: collector, waiter: FakeWaiter(), signals: signals, stdout: stdout)
        XCTAssertEqual(CLIRunner.run(.watch(interval: 1, count: nil), json: false, pretty: false, environment: environment), 130)
        XCTAssertEqual(stdout.lines.count, 1)
    }

    func testSIGTERMProducesDocumentedExitStatus() {
        let environment = makeEnvironment(
            collector: SpyCollector(),
            waiter: FakeWaiter(),
            signals: ScriptedSignals([SIGTERM]),
            stdout: CapturingStdout()
        )
        XCTAssertEqual(CLIRunner.run(.watch(interval: 1, count: nil), json: false, pretty: false, environment: environment), 143)
    }

    func testSignalCheckHappensBeforeNextCollectionSoNoPartialLineIsWritten() {
        let collector = SpyCollector()
        let stdout = CapturingStdout()
        let signals = ScriptedSignals([SIGINT, nil, nil])
        let environment = makeEnvironment(collector: collector, waiter: FakeWaiter(), signals: signals, stdout: stdout)
        XCTAssertEqual(CLIRunner.run(.watch(interval: 1, count: nil), json: false, pretty: false, environment: environment), 130)
        // Only the priming collection happened; the interrupted iteration
        // collected nothing and wrote nothing.
        XCTAssertEqual(collector.recordedRequests, [false])
        XCTAssertTrue(stdout.text.isEmpty)
    }

    func testSamplePrimedThroughWaiterNotRealSleep() throws {
        let collector = SpyCollector(samples: [
            SystemSample.placeholder,
            SystemSample.placeholder
        ])
        let waiter = FakeWaiter()
        let stdout = CapturingStdout()
        let environment = makeEnvironment(collector: collector, waiter: waiter, signals: ScriptedSignals([]), stdout: stdout)
        XCTAssertEqual(CLIRunner.run(.sample(interval: 5), json: false, pretty: false, environment: environment), 0)
        XCTAssertEqual(waiter.recordedWaits, [5])
        XCTAssertEqual(collector.recordedRequests, [false, true])
        XCTAssertEqual(stdout.lines.count, 1)
    }

    func testPrimingHelperWaitsOneRequestedIntervalAndForcesTheDiskRead() {
        let collector = SpyCollector()
        let waiter = FakeWaiter()
        _ = CLIRunner.collectPrimedSample(collector: collector, intervalSeconds: 7, waiter: waiter)
        XCTAssertEqual(collector.recordedRequests, [false, true])
        XCTAssertEqual(waiter.recordedWaits, [7])
    }

    func testStatusUsesSharedDerivationsAndStaleHistoryReason() throws {
        let output = CapturingStdout()
        let archive = workDirectory.appendingPathComponent("absent-history.plist")
        let environment = CLIRunner.Environment(
            stdout: output,
            waiter: FakeWaiter(),
            signals: ScriptedSignals([]),
            collector: SpyCollector(),
            version: CLIVersionInfo(searoomVersion: "test", buildNumber: "0", macosFloor: "14.0"),
            now: { Date(timeIntervalSinceReferenceDate: 1_000) },
            archiveURL: archive
        )
        XCTAssertEqual(CLIRunner.run(.status(interval: 2), json: false, pretty: false, environment: environment), 0)
        let object = try JSONSerialization.jsonObject(with: Data(output.text.utf8)) as! [String: Any]
        XCTAssertEqual(object["document"] as? String, "status")
        let context = try XCTUnwrap(object["historyContext"] as? [String: Any])
        XCTAssertEqual(context["usableForSustained"] as? Bool, false)
        XCTAssertEqual(context["unusableReason"] as? String, "history-missing")
        // An empty archive can never claim sustained pressure.
        XCTAssertTrue(object["sustained"] is NSNull)
    }

    func testSustainedContextRequiresFreshHistory() {
        let raw = SystemSample.placeholder
        let old = Date(timeIntervalSinceReferenceDate: 0)
        // Missing history.
        let missing = CLIRunner.makeSustainedContext(raw: raw, archive: [], now: Date())
        XCTAssertNil(missing.sustained)
        XCTAssertEqual(missing.context.unusableReason, "history-missing")
        // Stale history: last sample far older than the freshness budget.
        let staleArchive = [old].map { date -> SystemSample in
            let data = try! JSONEncoder().encode(raw)
            var object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
            object["timestamp"] = date.timeIntervalSinceReferenceDate
            return try! JSONDecoder().decode(SystemSample.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let staleContext = CLIRunner.makeSustainedContext(raw: raw, archive: staleArchive, now: Date())
        XCTAssertNil(staleContext.sustained)
        XCTAssertEqual(staleContext.context.unusableReason, "history-stale")
        XCTAssertNotNil(staleContext.context.lastTimestamp)
        XCTAssertTrue((staleContext.context.lagSeconds ?? 0) > 120)
    }

    func testLimitingResourcesRetainTiesAndSkipNominal() {
        func sampleWith(level: PressureLevel, gpuLevel: PressureLevel = .unavailable) -> SystemSample {
            let data = try! JSONEncoder().encode(SystemSample.placeholder)
            var object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
            object["cpuPressureLevel"] = level.rawValue
            object["memoryPressureLevel"] = level.rawValue
            object["gpuPressureLevel"] = gpuLevel.rawValue
            object["availability"] = ["cpuUsageLoad": "available", "vmStatistics": "available", "gpu": "available"]
            return try! JSONDecoder().decode(SystemSample.self, from: JSONSerialization.data(withJSONObject: object))
        }

        // Nominal everywhere: nothing is limiting.
        XCTAssertTrue(TelemetryDerivedMetrics.limitingResources(in: sampleWith(level: .nominal)).isEmpty)

        // Tied constrained CPU and memory both appear; unavailable GPU never does.
        let limiting = TelemetryDerivedMetrics.limitingResources(in: sampleWith(level: .constrained))
        XCTAssertEqual(Set(limiting.map(\.resource)), ["cpu", "memory"])
    }

    // MARK: - history --jsonl

    /// Each line must be the same envelope `watch` streams, so one reader
    /// handles both and every line validates against the published schema.
    func testHistoryJSONLinesEmitsOneSampleDocumentPerLine() throws {
        let directory = workDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("history.plist")
        XCTAssertTrue(HistoryArchiveStore(fileURL: archive).save([.placeholder, .placeholder]))

        let stdout = CapturingStdout()
        let environment = CLIRunner.Environment(
            stdout: stdout,
            waiter: FakeWaiter(),
            signals: ScriptedSignals([]),
            collector: SpyCollector(),
            version: CLIVersionInfo(searoomVersion: "test", buildNumber: "0", macosFloor: "14.0"),
            now: { Date(timeIntervalSinceReferenceDate: 1_000) },
            archiveURL: archive
        )

        let exit = CLIRunner.run(
            .history(filter: HistoryFilter(since: nil, until: nil, limit: nil), jsonl: true),
            json: false,
            pretty: false,
            environment: environment
        )
        XCTAssertEqual(exit, 0)

        let lines = stdout.text.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2)
        for line in lines {
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            )
            XCTAssertEqual(object["document"] as? String, "sample")
            XCTAssertEqual(object["$schema"] as? String, TelemetryOutputV1.schemaURL)
            XCTAssertNotNil(object["sample"])
            // These came out of the archive; they are not live CLI telemetry.
            let source = object["source"] as? [String: Any]
            XCTAssertEqual(source?["kind"] as? String, "persisted")
            XCTAssertEqual(source?["producer"] as? String, "searoom-app")
            XCTAssertNil(source?["requestedIntervalSeconds"] as? Int)
        }
    }

    // MARK: - Production wiring

    /// Every signal test injects a double, so the whole suite passed while the
    /// shipping binary defaulted to the no-op monitor and `watch` was killed by
    /// SIGINT instead of finishing its line and returning 128 + signal. Assert
    /// the default the binary actually gets.
    func testProductionEnvironmentInstallsTheRealSignalMonitor() {
        let environment = CLIRunner.Environment()
        XCTAssertTrue(
            environment.signals is CLIRunner.DispatchSignalMonitor,
            "watch's line-boundary guarantee needs the dispatch monitor, not \(type(of: environment.signals))"
        )
    }

    /// SIG_IGN plus a dispatch source must survive installing twice, because
    /// nothing stops a caller constructing two environments in one process.
    func testInstallingTheSignalMonitorTwiceIsHarmless() {
        let monitor = CLIRunner.DispatchSignalMonitor()
        monitor.install()
        monitor.install()
        XCTAssertNil(monitor.interruptedSignal)
    }
}
