import Foundation

/// Executes parsed CLI commands. The runner is synchronous and Foundation-only
/// so it never touches AppKit and stays extractable from the app target.
enum CLIRunner {
    // MARK: - Injected dependencies (unit tests replace these)

    /// Collection seam so sampling tests can spy on warm-up behavior without
    /// sleeping. `SystemMetricsCollector` conforms unchanged.
    protocol Sampling: AnyObject {
        func collect(forceDiskCounterRefresh: Bool) -> SystemSample
    }

    protocol Stdout: Sendable {
        func write(_ data: Data)
    }

    struct FileHandleStdout: Stdout {
        let handle: FileHandle
        init(_ handle: FileHandle = .standardOutput) { self.handle = handle }
        func write(_ data: Data) { handle.write(data) }
    }

    protocol Waiter: Sendable {
        func wait(seconds: Double)
    }

    struct ThreadWaiter: Waiter {
        func wait(seconds: Double) { Thread.sleep(forTimeInterval: seconds) }
    }

    /// Signal observation. The default implementation exits the watch loop at
    /// a line boundary so no partial JSON record is ever emitted.
    protocol SignalMonitor: Sendable {
        func install()
        var interruptedSignal: Int32? { get }
    }

    struct NoSignals: SignalMonitor {
        func install() {}
        var interruptedSignal: Int32? { nil }
    }

    final class DispatchSignalMonitor: SignalMonitor, @unchecked Sendable {
        private let lock = NSLock()
        private var interrupted: Int32?
        private var sources: [DispatchSourceSignal] = []

        func install() {
            lock.lock()
            defer { lock.unlock() }
            guard sources.isEmpty else { return }
            for signalNumber in [SIGINT, SIGTERM] {
                signal(signalNumber, SIG_IGN)
                let source = DispatchSource.makeSignalSource(
                    signal: signalNumber,
                    queue: DispatchQueue.global(qos: .userInitiated)
                )
                source.setEventHandler { [weak self] in
                    self?.record(signalNumber)
                }
                source.resume()
                sources.append(source)
            }
        }

        private func record(_ signalNumber: Int32) {
            lock.lock()
            defer { lock.unlock() }
            if interrupted == nil { interrupted = signalNumber }
        }

        var interruptedSignal: Int32? {
            lock.lock()
            defer { lock.unlock() }
            return interrupted
        }
    }

    // MARK: - Entry point

    struct Environment {
        let stdout: Stdout
        let stderr: TextOutputStream
        let waiter: Waiter
        let signals: SignalMonitor
        let collector: Sampling
        let version: CLIVersionInfo
        let now: () -> Date
        let archiveURL: URL

        init(
            stdout: Stdout = FileHandleStdout(),
            waiter: Waiter = ThreadWaiter(),
            signals: SignalMonitor = DispatchSignalMonitor(),
            collector: Sampling = SystemMetricsCollector(),
            version: CLIVersionInfo = .current(),
            now: @escaping () -> Date = Date.init,
            archiveURL: URL = HistoryArchiveStore.defaultArchiveURL()
        ) {
            self.stdout = stdout
            self.waiter = waiter
            self.signals = signals
            self.collector = collector
            self.version = version
            self.now = now
            self.archiveURL = archiveURL
            self.stderr = StandardError()
        }
    }

    private struct StandardError: TextOutputStream {
        mutating func write(_ string: String) {
            FileHandle.standardError.write(Data(string.utf8))
        }
    }

    /// Runs a parsed command and returns the process exit code.
    static func run(
        _ command: CLICommandKind,
        json: Bool,
        pretty: Bool,
        environment: Environment = Environment()
    ) -> Int32 {
        do {
            return try execute(command, json: json, pretty: pretty, environment: environment)
        } catch let error as CLIError {
            FileHandle.standardError.write(Data("searoom: \(error.message)\n".utf8))
            return error.exitCode.rawValue
        } catch {
            FileHandle.standardError.write(Data("searoom: \(error)\n".utf8))
            return CLIExitCode.softwareError.rawValue
        }
    }

    static func usageError(_ error: CLIError) -> Int32 {
        FileHandle.standardError.write(Data("searoom: \(error.message)\n".utf8))
        FileHandle.standardError.write(Data("Run `searoom help` for the command reference.\n".utf8))
        return error.exitCode.rawValue
    }

    private static func execute(
        _ command: CLICommandKind,
        json: Bool,
        pretty: Bool,
        environment: Environment
    ) throws -> Int32 {
        switch command {
        case .help(let topic):
            return try help(topic: topic, json: json, environment: environment)
        case .version:
            return version(json: json, environment: environment)
        case .sample(let interval):
            return try sample(interval: interval, pretty: pretty, environment: environment)
        case .watch(let interval, let count):
            return watch(interval: interval, count: count, environment: environment)
        case .status(let interval):
            return try status(interval: interval, pretty: pretty, environment: environment)
        case .history(let filter, let jsonl):
            return try history(filter: filter, jsonl: jsonl, pretty: pretty, environment: environment)
        case .capabilities:
            return try capabilities(pretty: pretty, environment: environment)
        case .metrics(let metric):
            return try metrics(metric: metric, json: json, environment: environment)
        case .schema:
            return try emitBundledResource("telemetry-v1.schema", extension: "json", environment: environment)
        case .agentGuide:
            return try emitBundledResource("SKILL", extension: "md", environment: environment)
        case .selfTest:
            return SelfTest.runCLI()
        case .installCLI:
            return CLIInstaller.runInstall()
        case .uninstallCLI:
            return CLIInstaller.runUninstall()
        case .legacyDumpSample:
            return SelfTest.dumpSample() ? 0 : 1
        }
    }

    // MARK: - Output helpers

    private static func emit(_ data: Data, environment: Environment) {
        environment.stdout.write(data)
        environment.stdout.write(Data("\n".utf8))
    }

    private static func emitJSON<T: Encodable>(
        _ value: T,
        pretty: Bool,
        environment: Environment
    ) throws {
        let data = try TelemetryOutputV1.encode(value, pretty: pretty)
        emit(data, environment: environment)
    }

    private static func emitBundledResource(
        _ name: String,
        extension resourceExtension: String,
        environment: Environment
    ) throws -> Int32 {
        for subdirectory in [nil, "CLI", "AgentSkills/interpret-searoom-telemetry"] as [String?] {
            guard let url = Bundle.module.url(
                forResource: name,
                withExtension: resourceExtension,
                subdirectory: subdirectory
            ) else { continue }
            guard let data = try? Data(contentsOf: url) else {
                throw CLIError(exitCode: .softwareError, message: "cannot read bundled \(name).\(resourceExtension)")
            }
            environment.stdout.write(data)
            if data.last != UInt8(ascii: "\n") {
                environment.stdout.write(Data("\n".utf8))
            }
            return 0
        }
        throw CLIError(exitCode: .softwareError, message: "bundled \(name).\(resourceExtension) is missing")
    }

    private static func loadBundledMetrics() throws -> [MetricDefinitionV1] {
        try CLIMetricResource.loadDefinitions()
    }

    // MARK: - help / version

    private static func help(topic: String?, json: Bool, environment: Environment) throws -> Int32 {
        let catalog = CLICommandCatalog.make()
        if json {
            try emitJSON(
                HelpCatalogDocumentV1(
                    catalog: catalog,
                    version: environment.version,
                    generatedAt: environment.now()
                ),
                pretty: true,
                environment: environment
            )
            return 0
        }
        if let topic {
            guard let command = catalog.commands.first(where: { $0.name == topic }) else {
                throw CLIError(exitCode: .usage, message: "unknown command \(topic)")
            }
            emit(Data(Self.describe(command).utf8), environment: environment)
            return 0
        }
        var text = """
        searoom — local, offline macOS capacity telemetry

        Usage: searoom COMMAND [OPTIONS]

        Commands:
        """
        for command in catalog.commands {
            text += "\n  \(command.name.padding(toLength: 14, withPad: " ", startingAt: 0))\(command.summary)"
        }
        text += """

        Legacy flags (unchanged behavior):
          Searoom --dump-sample    One JSON sample in the persisted 41-field shape
          Searoom --self-test      Framework-independent collector checks

        Run `searoom help COMMAND` for details, `searoom schema` for the JSON
        Schema of every telemetry document, and `searoom metrics` for metric
        semantics. Every command is offline and read-only except install-cli.
        """
        emit(Data(text.utf8), environment: environment)
        return 0
    }

    private static func describe(_ command: CLICommandCatalog.Command) -> String {
        var text = "\(command.name) — \(command.summary)\n"
        if command.arguments.isEmpty {
            text += "  Arguments: none\n"
        } else {
            text += "  Arguments:\n"
            for argument in command.arguments {
                var line = "    \(argument.name) (\(argument.kind)"
                if argument.required { line += ", required" }
                if let defaultValue = argument.defaultValue { line += ", default \(defaultValue)" }
                if let validValues = argument.validValues { line += ", one of \(validValues.joined(separator: ", "))" }
                line += ")\n"
                text += line
            }
        }
        text += "  Output: \(command.outputDocument)\n"
        text += "  Side effects: \(command.changesFilesystem ? "changes the filesystem (ask the user before running)" : "none")\n"
        text += "  Exit codes: \(command.exitCodes.map(String.init).joined(separator: ", "))\n"
        return text
    }

    private static func version(json: Bool, environment: Environment) -> Int32 {
        if json {
            do {
                try emitJSON(
                    VersionDocumentV1(version: environment.version, generatedAt: environment.now()),
                    pretty: false,
                    environment: environment
                )
            } catch {
                FileHandle.standardError.write(Data("searoom: \(error)\n".utf8))
                return CLIExitCode.softwareError.rawValue
            }
            return 0
        }
        let text = """
        searoom \(environment.version.searoomVersion) (build \(environment.version.buildNumber))
        telemetry schema version \(TelemetryOutputV1.schemaVersion)
        macOS floor \(environment.version.macosFloor)
        """
        emit(Data(text.utf8), environment: environment)
        return 0
    }

    // MARK: - Live sampling

    /// One priming sample installs every rate baseline, then one requested
    /// interval of monotonic time passes, then a forced second disk-counter
    /// read completes the disk baseline so the emitted sample carries
    /// meaningful disk I/O.
    static func collectPrimedSample(
        collector: Sampling,
        intervalSeconds: Int,
        waiter: Waiter
    ) -> SystemSample {
        _ = collector.collect(forceDiskCounterRefresh: false)
        waiter.wait(seconds: Double(intervalSeconds))
        return collector.collect(forceDiskCounterRefresh: true)
    }

    private static func resolvedInterval(_ requested: Int?) -> Int {
        requested ?? 2
    }

    private static func sample(
        interval: Int?,
        pretty: Bool,
        environment: Environment
    ) throws -> Int32 {
        let seconds = resolvedInterval(interval)
        let raw = collectPrimedSample(
            collector: environment.collector,
            intervalSeconds: seconds,
            waiter: environment.waiter
        )
        let document = SampleDocumentV1(
            sample: .make(from: raw, observerKind: "searoom-cli"),
            intervalSeconds: seconds,
            generatedAt: environment.now(),
            version: environment.version
        )
        try emitJSON(document, pretty: pretty, environment: environment)
        return 0
    }

    private static func watch(
        interval: Int?,
        count: Int?,
        environment: Environment
    ) -> Int32 {
        let seconds = resolvedInterval(interval)
        let clock = ContinuousClock()
        environment.signals.install()
        _ = environment.collector.collect(forceDiskCounterRefresh: false)
        var deadline = clock.now
        var emitted = 0

        while count == nil || emitted < (count ?? 0) {
            deadline = deadline.advanced(by: .seconds(Double(seconds)))
            // Sleep to the monotonic deadline through the injectable waiter so
            // collection duration never accumulates drift.
            let remaining = clock.now.duration(to: deadline)
            let remainingSeconds = Double(remaining.components.seconds)
                + Double(remaining.components.attoseconds) / 1e18
            if remainingSeconds > 0 {
                environment.waiter.wait(seconds: remainingSeconds)
            }
            if let signal = environment.signals.interruptedSignal {
                return CLIExitCode.terminated(bySignal: signal)
            }
            // The first emitted line needs the forced disk-counter read; later
            // lines use the normal five-second cache cadence.
            let raw = environment.collector.collect(forceDiskCounterRefresh: emitted == 0)
            let document = SampleDocumentV1(
                sample: .make(from: raw, observerKind: "searoom-cli"),
                intervalSeconds: seconds,
                generatedAt: environment.now(),
                version: environment.version
            )
            guard let data = try? TelemetryOutputV1.encode(document, pretty: false) else {
                FileHandle.standardError.write(Data("searoom: sample encoding failed\n".utf8))
                return CLIExitCode.softwareError.rawValue
            }
            environment.stdout.write(data)
            environment.stdout.write(Data("\n".utf8))
            emitted += 1
        }
        return 0
    }

    // MARK: - status

    private static func status(
        interval: Int?,
        pretty: Bool,
        environment: Environment
    ) throws -> Int32 {
        let seconds = resolvedInterval(interval)
        let raw = collectPrimedSample(
            collector: environment.collector,
            intervalSeconds: seconds,
            waiter: environment.waiter
        )
        let archive = readHistoryForStatus(environment: environment)
        let derived = Self.makeDerived(raw)
        let sustainedContext = Self.makeSustainedContext(raw: raw, archive: archive, now: environment.now())

        let document = StatusDocumentV1(
            sample: .make(from: raw, observerKind: "searoom-cli"),
            raw: raw,
            limiting: Self.makeLimiting(raw),
            derived: derived,
            sustained: sustainedContext.sustained,
            historyContext: sustainedContext.context,
            intervalSeconds: seconds,
            version: environment.version,
            generatedAt: environment.now()
        )
        try emitJSON(document, pretty: pretty, environment: environment)
        return 0
    }

    static func makeDerived(_ raw: SystemSample) -> StatusDocumentV1.Derived {
        StatusDocumentV1.Derived(
            memoryUsedFraction: TelemetryDerivedMetrics.memoryUsedFraction(raw),
            memoryCompressedFraction: TelemetryDerivedMetrics.memoryCompressedFraction(raw),
            gpuWorkingSetHeadroomBytes: TelemetryDerivedMetrics.gpuWorkingSetHeadroomBytes(raw),
            diskUsedBytes: raw.diskUsedBytes,
            diskUsedFraction: raw.diskUsedFraction.flatMap(TelemetryOutputV1.finite),
            powerStateLabel: TelemetryDerivedMetrics.powerStateLabel(raw),
            swapActivityState: TelemetryDerivedMetrics.swapActivityState(raw),
            fanState: TelemetryDerivedMetrics.fanState(raw),
            observerState: TelemetryDerivedMetrics.observerState(raw)
        )
    }

    static func makeLimiting(_ raw: SystemSample) -> [LimitingResourceV1] {
        TelemetryDerivedMetrics.limitingResources(in: raw).map {
            LimitingResourceV1(
                resource: $0.resource,
                level: $0.level.outputLabel,
                valueFraction: $0.valueFraction.flatMap(TelemetryOutputV1.finite)
            )
        }
    }

    /// Sustained duration comes from persisted history only when that history
    /// is fresh enough to be meaningful. A single sample is never evidence of
    /// a sustained run.
    static func makeSustainedContext(
        raw: SystemSample,
        archive: [SystemSample],
        now: Date
    ) -> (sustained: StatusDocumentV1.Sustained?, context: StatusDocumentV1.HistoryContext) {
        let lastTimestamp = archive.last?.timestamp
        let lag = lastTimestamp.map { max(0, now.timeIntervalSince($0)) }
        // History is usable when its newest sample is no older than two
        // minutes: twice the write cadence, so a normal pause between
        // persists does not disqualify it.
        let freshnessBudget: TimeInterval = 120
        let usable = lastTimestamp != nil && (lag ?? 0) <= freshnessBudget

        var sustained: StatusDocumentV1.Sustained?
        var reason: String?
        if archive.isEmpty {
            reason = "history-missing"
        } else if !usable {
            reason = "history-stale"
        } else if let reading = SustainedPressure.duration(in: archive),
                  reading.level == raw.overallPressureLevel, reading.level != .unavailable {
            sustained = StatusDocumentV1.Sustained(
                level: reading.level.outputLabel,
                durationSeconds: reading.duration,
                boundedByHistoryWindow: reading.boundedByHistoryWindow
            )
        } else if raw.overallPressureLevel == .unavailable {
            reason = "overall-pressure-unavailable"
        } else {
            reason = "current-level-not-sustained"
        }

        let context = StatusDocumentV1.HistoryContext(
            lastTimestamp: lastTimestamp,
            lagSeconds: lag.flatMap(TelemetryOutputV1.finite),
            approximateLagSeconds: TelemetryOutputV1.approximateHistoryLagSeconds,
            usableForSustained: usable,
            unusableReason: reason
        )
        return (sustained, context)
    }

    // MARK: - history

    enum HistoryLoad {
        case samples([SystemSample])
        case failure(CLIError)
    }

    /// CLI history reading: missing is an empty success; corrupt,
    /// unsupported, and oversized archives are `EX_DATAERR` diagnostics.
    static func loadHistoryForCLI(environment: Environment) -> HistoryLoad {
        let store = HistoryArchiveStore(fileURL: environment.archiveURL, limits: .conservative)
        switch store.load() {
        case .samples(let samples):
            return .samples(samples)
        case .missing:
            return .samples([])
        case .corrupt(let reason):
            return .failure(CLIError(exitCode: .dataError, message: "history archive is corrupt: \(reason)"))
        case .unsupported(let version):
            return .failure(
                CLIError(
                    exitCode: .dataError,
                    message: "history archive version \(version.map(String.init) ?? "unknown") is not supported"
                )
            )
        case .oversized:
            return .failure(CLIError(exitCode: .dataError, message: "history archive exceeds the accepted size or sample count"))
        }
    }

    private static func readHistoryForStatus(environment: Environment) -> [SystemSample] {
        // Status is a live reading; unusable history only degrades the
        // sustained context, so every failure degrades to empty instead of
        // failing the command.
        if case .samples(let samples) = loadHistoryForCLI(environment: environment) {
            return samples
        }
        return []
    }

    private static func history(
        filter: HistoryFilter,
        jsonl: Bool,
        pretty: Bool,
        environment: Environment
    ) throws -> Int32 {
        let loaded = loadHistoryForCLI(environment: environment)
        guard case .samples(let archive) = loaded else {
            if case .failure(let error) = loaded { throw error }
            return 0
        }
        // Sustained context is computed from the full archive before filters.
        let resolved = try filter.resolve(now: environment.now())
        let matching = filter.apply(archive, to: resolved)
        let projected = matching.map { TelemetrySampleV1.make(from: $0, observerKind: "searoom-app") }

        if jsonl {
            // The same document `watch` streams, so one reader handles both and
            // every line validates against the published schema. A bare sample
            // would not: the schema's top level requires the envelope.
            // There is no sampling interval to report for a persisted sample.
            for sample in projected {
                let document = SampleDocumentV1(
                    sample: sample,
                    source: .persistedHistory,
                    generatedAt: environment.now(),
                    version: environment.version
                )
                let data = try TelemetryOutputV1.encode(document, pretty: false)
                environment.stdout.write(data)
                environment.stdout.write(Data("\n".utf8))
            }
            return 0
        }
        let document = HistoryDocumentV1(
            samples: projected,
            archive: archive,
            archivePath: environment.archiveURL.path,
            version: environment.version,
            generatedAt: environment.now()
        )
        try emitJSON(document, pretty: pretty, environment: environment)
        return 0
    }

    // MARK: - capabilities

    private static func capabilities(
        pretty: Bool,
        environment: Environment
    ) throws -> Int32 {
        let seconds = resolvedInterval(nil)
        let raw = collectPrimedSample(
            collector: environment.collector,
            intervalSeconds: seconds,
            waiter: environment.waiter
        )
        let availability = raw.availability
        let groups: [CapabilityV1] = [
            CapabilityV1(
                group: "cpu",
                availability: availability.cpuUsageLoad.rawValue,
                source: "host_statistics CPU ticks and getloadavg",
                refreshCadenceSeconds: seconds,
                notes: "pressure is derived, not macOS PSI"
            ),
            CapabilityV1(
                group: "memory",
                availability: availability.vmStatistics.rawValue,
                source: "host_statistics64, vm.swapusage, kern.memorystatus_vm_pressure_level",
                refreshCadenceSeconds: seconds,
                notes: "swap and compression rates need one baseline sample"
            ),
            CapabilityV1(
                group: "temperature",
                availability: availability.temperature.rawValue,
                source: "AppleSMC CPU/package sensor, AppleSmartBattery fallback",
                refreshCadenceSeconds: 6,
                notes: "source is labelled per reading; many Macs expose neither sensor"
            ),
            CapabilityV1(
                group: "fans",
                availability: availability.fans.rawValue,
                source: "AppleSMC fan speeds",
                refreshCadenceSeconds: 6,
                notes: "names are positional labels (FAN 1, FAN 2), not SMC names"
            ),
            CapabilityV1(
                group: "gpu",
                availability: availability.gpu.rawValue,
                source: "IORegistry PerformanceStatistics and Metal recommendedMaxWorkingSetSize",
                refreshCadenceSeconds: 7,
                notes: "unavailable without a supported IOAccelerator utilization key"
            ),
            CapabilityV1(
                group: "network",
                availability: availability.networkIO.rawValue,
                source: "getifaddrs over active non-loopback interfaces",
                refreshCadenceSeconds: seconds,
                notes: nil
            ),
            CapabilityV1(
                group: "diskIO",
                availability: availability.diskIO.rawValue,
                source: "IOBlockStorageDriver Statistics byte counters",
                refreshCadenceSeconds: 5,
                notes: nil
            ),
            CapabilityV1(
                group: "diskCapacity",
                availability: availability.diskCapacity.rawValue,
                source: "statfs on the root volume",
                refreshCadenceSeconds: 30,
                notes: "available excludes purgeable files; capacity is neutral, never a pressure level"
            ),
            CapabilityV1(
                group: "battery",
                availability: availability.battery.rawValue,
                source: "IOPowerSources and AppleSmartBattery",
                refreshCadenceSeconds: 30,
                notes: "unavailable on desktop Macs"
            ),
            CapabilityV1(
                group: "processCount",
                availability: availability.processCount.rawValue,
                source: "proc_listallpids",
                refreshCadenceSeconds: 60,
                notes: nil
            ),
            CapabilityV1(
                group: "observer",
                availability: availability.processCPU.rawValue,
                source: "getrusage and mach task_info for this process",
                refreshCadenceSeconds: seconds,
                notes: "describes the searoom-cli process, not the menu-bar app"
            )
        ]
        try emitJSON(
            CapabilitiesDocumentV1(
                groups: groups,
                intervalSeconds: seconds,
                version: environment.version,
                generatedAt: environment.now()
            ),
            pretty: pretty,
            environment: environment
        )
        return 0
    }

    // MARK: - metrics

    private static func metrics(
        metric: String?,
        json: Bool,
        environment: Environment
    ) throws -> Int32 {
        let catalog = try loadBundledMetrics()
        if let metric {
            guard let definition = catalog.first(where: { $0.id == metric }) else {
                throw CLIError(exitCode: .usage, message: "unknown metric \(metric)")
            }
            if json {
                try emitJSON(definition, pretty: true, environment: environment)
            } else {
                emit(Data(Self.markdown(definition).utf8), environment: environment)
            }
            return 0
        }
        if json {
            try emitJSON(
                MetricCatalogDocumentV1(
                    metrics: catalog,
                    version: environment.version,
                    generatedAt: environment.now()
                ),
                pretty: true,
                environment: environment
            )
            return 0
        }
        emit(Data(Self.catalogMarkdown(catalog).utf8), environment: environment)
        return 0
    }

    /// The human-readable catalog is rendered from the bundled JSON at
    /// runtime, so the Markdown and the structured data cannot drift.
    static func catalogMarkdown(_ definitions: [MetricDefinitionV1]) -> String {
        var text = """
        # Searoom metric definitions (telemetry schema v1)

        Canonical units and semantics for every value the `searoom` CLI exports.
        Fractions use the closed range 0...1, byte sizes end in `Bytes`, rates end
        in `BytesPerSecond`, durations are seconds, and temperatures are Celsius.
        Unavailable readings are explicit `null` with an availability reason:
        `available` (measured, zero means zero), `warmingUp` (no rate baseline yet),
        `unavailable` (read failed), or `legacyUnknown` (persisted before metadata
        existed). Utilization-derived pressure levels are nominal below 0.70,
        elevated from 0.70, constrained from 0.85, and critical from 0.95.

        Run `searoom metrics <ID>` for one entry, `searoom metrics --json` for this
        catalog as structured data, and `searoom schema` for the JSON Schema.

        """
        for definition in definitions {
            text += "## \(definition.id)\n\n"
            text += definitionBody(definition)
            text += "\n"
        }
        return text
    }

    static func markdown(_ definition: MetricDefinitionV1) -> String {
        "### \(definition.id)\n\n" + definitionBody(definition)
    }

    private static func definitionBody(_ definition: MetricDefinitionV1) -> String {
        var text = """
        - Path: `\(definition.jsonPath)`
        - Display name: \(definition.displayName)
        - Unit: \(definition.unit)
        - Range: \(definition.range)
        - Nullable: \(definition.nullable ? "yes" : "no")
        - Source: \(definition.source) (\(definition.sourceStability))
        - Refresh cadence: \(definition.refreshCadence)
        - First sample: \(definition.firstSampleBehavior)
        - Rollback: \(definition.rollbackBehavior)

        """
        if let derivation = definition.derivation {
            text += "Derivation: \(derivation)\n\n"
        }
        if let thresholds = definition.thresholds {
            text += """
            Thresholds: elevated ≥ \(thresholds.elevated), constrained ≥ \(thresholds.constrained), critical ≥ \(thresholds.critical)

            """
        }
        if !definition.limitations.isEmpty {
            text += "Limitations:\n"
            for limitation in definition.limitations { text += "- \(limitation)\n" }
            text += "\n"
        }
        if !definition.interpretationNotes.isEmpty {
            text += "Interpretation:\n"
            for note in definition.interpretationNotes { text += "- \(note)\n" }
        }
        return text
    }
}

extension SystemMetricsCollector: CLIRunner.Sampling {}
