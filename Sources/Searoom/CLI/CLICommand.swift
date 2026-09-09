import Foundation

/// Exit codes follow BSD `sysexits.h` plus the conventional `128 + signal`
/// statuses for a `watch` loop interrupted by a signal.
enum CLIExitCode: Int32 {
    case success = 0
    case usage = 64
    case dataError = 65
    case softwareError = 70
    case ioError = 74

    static func terminated(bySignal signal: Int32) -> Int32 { 128 + signal }
}

struct CLIError: Error, Equatable {
    let exitCode: CLIExitCode
    let message: String
}

/// The invocation basename decides the no-argument default: the signed app
/// bundle executable launches the GUI, a lowercase `searoom` symlink prints
/// help. Every other behavior is identical through both entry points.
enum CLIInvocationStyle {
    case appBundle
    case cliCommand

    static func from(executablePath: String) -> CLIInvocationStyle {
        // Deliberately case-sensitive: the signed bundle executable is
        // `Searoom`; only a lowercase `searoom` symlink invokes the CLI.
        (executablePath as NSString).lastPathComponent == "searoom" ? .cliCommand : .appBundle
    }
}

enum CLICommandKind: Equatable {
    case help(command: String?)
    case version
    case sample(interval: Int?)
    case watch(interval: Int?, count: Int?)
    case status(interval: Int?)
    case history(filter: HistoryFilter)
    case capabilities
    case metrics(metric: String?)
    case schema
    case agentGuide
    case selfTest
    case installCLI
    case uninstallCLI
    case legacyDumpSample
}

/// A parsed invocation ready for execution, or a decision about the GUI.
enum CLIParsedInvocation: Equatable {
    case launchGUI
    case run(CLICommandKind, json: Bool, pretty: Bool)
    case usageError(CLIError)
}

/// A relative duration (`30m`, `3h`, `2d`) or an absolute UTC RFC 3339
/// timestamp. The token is validated at parse time and anchored to "now" at
/// execution time, so a filter can be parsed once and resolved against the
/// real clock.
enum CLITimeBound: Equatable {
    case absolute(Date)
    case relative(seconds: TimeInterval, token: String)

    static func parse(_ token: String) -> CLITimeBound? {
        if let date = CLIDateFormat.parseRFC3339(token) {
            return .absolute(date)
        }
        return Self.parseRelative(token).map { .relative(seconds: $0, token: token) }
    }

    static func parseRelative(_ token: String) -> TimeInterval? {
        // A bare number is seconds; otherwise the trailing unit letter decides.
        guard !token.isEmpty else { return nil }
        let unit: TimeInterval
        let digits: Substring
        switch token.last {
        case "s": unit = 1; digits = token.dropLast()
        case "m": unit = 60; digits = token.dropLast()
        case "h": unit = 3_600; digits = token.dropLast()
        case "d": unit = 86_400; digits = token.dropLast()
        default: unit = 1; digits = token[...]
        }
        guard let value = Double(digits), value.isFinite, value >= 0 else { return nil }
        return value * unit
    }

    func resolve(after now: Date) -> Date {
        switch self {
        case .absolute(let date): return date
        case .relative(let seconds, _): return now.addingTimeInterval(-seconds)
        }
    }
}

/// `--since` (inclusive) and `--until` (exclusive) bounds plus `--limit`,
/// mirroring the plan's history contract.
struct HistoryFilter: Equatable {
    let since: CLITimeBound?
    let until: CLITimeBound?
    let limit: Int?

    struct Resolved: Equatable {
        let since: Date?
        let until: Date?
    }

    func resolve(now: Date) throws -> Resolved {
        let lower = since.map { $0.resolve(after: now) }
        let upper = until.map { $0.resolve(after: now) }
        if let lower, let upper, lower >= upper {
            throw CLIError(exitCode: .usage, message: "--since must be earlier than --until")
        }
        return Resolved(since: lower, until: upper)
    }

    /// Applies the resolved bounds. `since` is inclusive, `until` exclusive.
    /// Input must already be chronological; output preserves that order.
    func apply(_ samples: [SystemSample], to resolved: Resolved) -> [SystemSample] {
        var matching = samples.filter { sample in
            if let lower = resolved.since, sample.timestamp < lower { return false }
            if let upper = resolved.until, sample.timestamp >= upper { return false }
            return true
        }
        if let limit, matching.count > limit {
            matching.removeFirst(matching.count - limit)
        }
        return matching
    }
}

enum CLIDateFormat {
    // Formatters are constructed per call: timestamp parsing happens once per
    // invocation, so this stays off shared mutable state entirely.
    private static func fractionalFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"
        return formatter
    }

    private static func wholeSecondsFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    /// Accepts RFC 3339 timestamps with or without fractional seconds.
    static func parseRFC3339(_ token: String) -> Date? {
        if let date = fractionalFormatter().date(from: token) { return date }
        return wholeSecondsFormatter().date(from: token)
    }

    /// UTC RFC 3339 with millisecond precision, matching the encoding rules.
    static func string(from date: Date) -> String {
        fractionalFormatter().string(from: date)
    }
}

enum CLIParser {
    /// Parses a full argument vector, including the executable path at index 0.
    static func parse(arguments: [String]) -> CLIParsedInvocation {
        guard arguments.count > 0 else {
            return .launchGUI
        }
        let style = CLIInvocationStyle.from(executablePath: arguments[0])
        let tokens = Array(arguments.dropFirst())

        guard !tokens.isEmpty else {
            switch style {
            case .appBundle:
                return .launchGUI
            case .cliCommand:
                return .run(.help(command: nil), json: false, pretty: false)
            }
        }

        // Legacy flags keep their exact existing behavior from either entry
        // point. Today any other unknown argument falls through to the GUI;
        // strict parsing replaces that with a usage error.
        if tokens.count == 1 {
            switch tokens[0] {
            case "--self-test":
                return .run(.selfTest, json: false, pretty: false)
            case "--dump-sample":
                return .run(.legacyDumpSample, json: false, pretty: false)
            case "--version":
                return .run(.version, json: false, pretty: false)
            case "--help":
                return .run(.help(command: nil), json: false, pretty: false)
            default:
                break
            }
        }

        do {
            let parsed = try parseCommand(tokens)
            return .run(parsed.command, json: parsed.json, pretty: parsed.pretty)
        } catch let error as CLIError {
            return .usageError(error)
        } catch {
            return .usageError(CLIError(exitCode: .usage, message: "\(error)"))
        }
    }

    private struct ParsedCommand {
        let command: CLICommandKind
        let json: Bool
        let pretty: Bool
    }

    private static func parseCommand(_ tokens: [String]) throws -> ParsedCommand {
        guard let first = tokens.first else {
            throw CLIError(exitCode: .usage, message: "missing command")
        }
        var rest = Array(tokens.dropFirst())
        var json = false
        var pretty = false
        var jsonl = false
        var interval: Int?
        var count: Int?
        var limit: Int?
        var since: CLITimeBound?
        var until: CLITimeBound?
        var positional: String?

        func takeValue(for option: String) throws -> String {
            guard !rest.isEmpty else {
                throw CLIError(exitCode: .usage, message: "\(option) requires a value")
            }
            return rest.removeFirst()
        }

        func markUsed(_ name: String, _ existing: Bool) throws {
            guard !existing else {
                throw CLIError(exitCode: .usage, message: "duplicate option \(name)")
            }
        }

        let commandName = first
        let command: CLICommandKind

        func parseIntervalOption(_ token: String) throws -> Int {
            guard let value = Int(token), (1...10).contains(value) else {
                throw CLIError(
                    exitCode: .usage,
                    message: "\(token) is not an interval from 1 through 10"
                )
            }
            return value
        }

        func parsePositiveInteger(_ token: String, option: String) throws -> Int {
            guard let value = Int(token), value >= 1, token.allSatisfy({ $0.isNumber }) else {
                throw CLIError(
                    exitCode: .usage,
                    message: "\(token) is not a positive whole number for \(option)"
                )
            }
            return value
        }

        func parseTimeBound(_ token: String, option: String) throws -> CLITimeBound {
            guard let bound = CLITimeBound.parse(token) else {
                throw CLIError(
                    exitCode: .usage,
                    message: "\(token) is not an RFC 3339 timestamp or relative duration for \(option)"
                )
            }
            return bound
        }

        func consumeOptions(allowed: Set<String>) throws {
            while let token = rest.first, token.hasPrefix("--") {
                rest.removeFirst()
                guard allowed.contains(token) else {
                    throw CLIError(
                        exitCode: .usage,
                        message: "option \(token) is not valid for this command"
                    )
                }
                switch token {
                case "--json":
                    try markUsed(token, json)
                    json = true
                case "--pretty":
                    try markUsed(token, pretty)
                    pretty = true
                case "--jsonl":
                    try markUsed(token, jsonl)
                    jsonl = true
                case "--interval":
                    try markUsed(token, interval != nil)
                    interval = try parseIntervalOption(takeValue(for: token))
                case "--count":
                    try markUsed(token, count != nil)
                    count = try parsePositiveInteger(takeValue(for: token), option: token)
                case "--limit":
                    try markUsed(token, limit != nil)
                    limit = try parsePositiveInteger(takeValue(for: token), option: token)
                case "--since":
                    try markUsed(token, since != nil)
                    since = try parseTimeBound(takeValue(for: token), option: token)
                case "--until":
                    try markUsed(token, until != nil)
                    until = try parseTimeBound(takeValue(for: token), option: token)
                default:
                    throw CLIError(exitCode: .usage, message: "unknown option \(token)")
                }
                _ = allowed
            }
        }

        switch commandName {
        case "help":
            try consumeOptions(allowed: ["--json"])
            if !rest.isEmpty { positional = rest.removeFirst() }
            guard rest.isEmpty else {
                throw CLIError(exitCode: .usage, message: "unexpected argument \(rest[0])")
            }
            if let positional, !CLICommandCatalog.names.contains(positional) {
                throw CLIError(exitCode: .usage, message: "unknown command \(positional)")
            }
            command = .help(command: positional)
        case "version":
            try consumeOptions(allowed: ["--json"])
            guard rest.isEmpty else {
                throw CLIError(exitCode: .usage, message: "unexpected argument \(rest[0])")
            }
            command = .version
        case "sample":
            try consumeOptions(allowed: ["--interval", "--pretty"])
            guard rest.isEmpty else {
                throw CLIError(exitCode: .usage, message: "unexpected argument \(rest[0])")
            }
            command = .sample(interval: interval)
        case "watch":
            try consumeOptions(allowed: ["--interval", "--count"])
            if pretty {
                throw CLIError(exitCode: .usage, message: "watch always emits JSON Lines and does not accept --pretty")
            }
            if jsonl {
                throw CLIError(exitCode: .usage, message: "watch always emits JSON Lines; --jsonl is implied")
            }
            guard rest.isEmpty else {
                throw CLIError(exitCode: .usage, message: "unexpected argument \(rest[0])")
            }
            command = .watch(interval: interval, count: count)
        case "status":
            try consumeOptions(allowed: ["--interval", "--pretty"])
            guard rest.isEmpty else {
                throw CLIError(exitCode: .usage, message: "unexpected argument \(rest[0])")
            }
            command = .status(interval: interval)
        case "history":
            try consumeOptions(allowed: ["--since", "--until", "--limit", "--jsonl", "--pretty"])
            guard rest.isEmpty else {
                throw CLIError(exitCode: .usage, message: "unexpected argument \(rest[0])")
            }
            command = .history(
                filter: HistoryFilter(since: since, until: until, limit: limit)
            )
        case "capabilities":
            try consumeOptions(allowed: ["--pretty"])
            guard rest.isEmpty else {
                throw CLIError(exitCode: .usage, message: "unexpected argument \(rest[0])")
            }
            command = .capabilities
        case "metrics":
            try consumeOptions(allowed: ["--json"])
            if !rest.isEmpty { positional = rest.removeFirst() }
            guard rest.isEmpty else {
                throw CLIError(exitCode: .usage, message: "unexpected argument \(rest[0])")
            }
            command = .metrics(metric: positional)
        case "schema":
            try consumeOptions(allowed: [])
            guard rest.isEmpty else {
                throw CLIError(exitCode: .usage, message: "unexpected argument \(rest[0])")
            }
            command = .schema
        case "agent-guide":
            try consumeOptions(allowed: [])
            guard rest.isEmpty else {
                throw CLIError(exitCode: .usage, message: "unexpected argument \(rest[0])")
            }
            command = .agentGuide
        case "self-test":
            try consumeOptions(allowed: [])
            guard rest.isEmpty else {
                throw CLIError(exitCode: .usage, message: "unexpected argument \(rest[0])")
            }
            command = .selfTest
        case "install-cli":
            try consumeOptions(allowed: [])
            guard rest.isEmpty else {
                throw CLIError(exitCode: .usage, message: "unexpected argument \(rest[0])")
            }
            command = .installCLI
        case "uninstall-cli":
            try consumeOptions(allowed: [])
            guard rest.isEmpty else {
                throw CLIError(exitCode: .usage, message: "unexpected argument \(rest[0])")
            }
            command = .uninstallCLI
        default:
            throw CLIError(exitCode: .usage, message: "unknown command \(commandName)")
        }

        return ParsedCommand(command: command, json: json, pretty: pretty)
    }
}

/// The machine-readable command catalog returned by `help --json`. It is also
/// the side-effect declaration an agent reads to know which commands change
/// the filesystem.
struct CLICommandCatalog: Encodable {
    struct Argument: Encodable {
        let name: String
        let kind: String
        let required: Bool
        let defaultValue: String?
        let validValues: [String]?
    }

    struct Command: Encodable {
        let name: String
        let summary: String
        let arguments: [Argument]
        let outputDocument: String
        let changesFilesystem: Bool
        let collectsTelemetry: Bool
        let exitCodes: [Int]
    }

    let schemaVersion: Int
    let commands: [Command]

    static let exitCodeVocabulary: [Int] = [0, 64, 65, 70, 74, 130, 143]

    static func argument(
        _ name: String,
        kind: String,
        required: Bool = false,
        defaultValue: String? = nil,
        validValues: [String]? = nil
    ) -> Argument {
        Argument(
            name: name,
            kind: kind,
            required: required,
            defaultValue: defaultValue,
            validValues: validValues
        )
    }

    static func make() -> CLICommandCatalog {
        let interval = argument(
            "--interval",
            kind: "integer seconds",
            defaultValue: "2",
            validValues: (1...10).map(String.init)
        )
        let pretty = argument("--pretty", kind: "flag")
        let json = argument("--json", kind: "flag")

        let commands: [Command] = [
            Command(
                name: "help",
                summary: "Print the command reference; --json returns this catalog.",
                arguments: [
                    argument("COMMAND", kind: "command name", validValues: Self.names),
                    json
                ],
                outputDocument: "text or help-catalog",
                changesFilesystem: false,
                collectsTelemetry: false,
                exitCodes: [0, 64]
            ),
            Command(
                name: "version",
                summary: "Print the app version, build number, schema version, and macOS floor.",
                arguments: [json],
                outputDocument: "text or version",
                changesFilesystem: false,
                collectsTelemetry: false,
                exitCodes: [0, 64]
            ),
            Command(
                name: "sample",
                summary: "Emit one fully primed live telemetry sample.",
                arguments: [interval, pretty],
                outputDocument: "sample",
                changesFilesystem: false,
                collectsTelemetry: true,
                exitCodes: [0, 64, 70]
            ),
            Command(
                name: "watch",
                summary: "Emit one compact sample document per line until interrupted or --count is reached.",
                arguments: [interval, argument("--count", kind: "positive integer", defaultValue: "unbounded")],
                outputDocument: "sample (one per line, JSON Lines)",
                changesFilesystem: false,
                collectsTelemetry: true,
                exitCodes: [0, 64, 70, 130, 143]
            ),
            Command(
                name: "status",
                summary: "Print current pressure, limiting signals, headroom, and sustained context.",
                arguments: [interval, pretty],
                outputDocument: "status",
                changesFilesystem: false,
                collectsTelemetry: true,
                exitCodes: [0, 64, 70]
            ),
            Command(
                name: "history",
                summary: "Print persisted samples from the app's local history archive without collecting.",
                arguments: [
                    argument("--since", kind: "RFC 3339 timestamp or relative duration"),
                    argument("--until", kind: "RFC 3339 timestamp or relative duration"),
                    argument("--limit", kind: "positive integer"),
                    argument("--jsonl", kind: "flag"),
                    pretty
                ],
                outputDocument: "history (or one sample per line with --jsonl)",
                changesFilesystem: false,
                collectsTelemetry: false,
                exitCodes: [0, 64, 65, 74]
            ),
            Command(
                name: "capabilities",
                summary: "Print metric-group availability, sources, and expected refresh cadence.",
                arguments: [pretty],
                outputDocument: "capabilities",
                changesFilesystem: false,
                collectsTelemetry: true,
                exitCodes: [0, 64, 70]
            ),
            Command(
                name: "metrics",
                summary: "Print bundled canonical metric definitions; --json emits the structured catalog.",
                arguments: [argument("METRIC", kind: "metric identifier"), json],
                outputDocument: "markdown or metric-catalog",
                changesFilesystem: false,
                collectsTelemetry: false,
                exitCodes: [0, 64, 70]
            ),
            Command(
                name: "schema",
                summary: "Print the bundled self-contained JSON Schema for all telemetry documents.",
                arguments: [],
                outputDocument: "json-schema",
                changesFilesystem: false,
                collectsTelemetry: false,
                exitCodes: [0, 70]
            ),
            Command(
                name: "agent-guide",
                summary: "Print the bundled Agent Skill explaining discovery and safe interpretation.",
                arguments: [],
                outputDocument: "markdown (Agent Skill)",
                changesFilesystem: false,
                collectsTelemetry: false,
                exitCodes: [0, 70]
            ),
            Command(
                name: "self-test",
                summary: "Run framework-independent collector and resource checks.",
                arguments: [],
                outputDocument: "text",
                changesFilesystem: false,
                collectsTelemetry: true,
                exitCodes: [0, 1, 70]
            ),
            Command(
                name: "install-cli",
                summary: "Create ~/.local/bin/searoom as a symlink to the installed app.",
                arguments: [],
                outputDocument: "text",
                changesFilesystem: true,
                collectsTelemetry: false,
                exitCodes: [0, 65, 74]
            ),
            Command(
                name: "uninstall-cli",
                summary: "Remove ~/.local/bin/searoom only when it targets the current app.",
                arguments: [],
                outputDocument: "text",
                changesFilesystem: true,
                collectsTelemetry: false,
                exitCodes: [0, 65, 74]
            )
        ]
        return CLICommandCatalog(schemaVersion: 1, commands: commands)
    }

    static let names: [String] = [
        "help", "version", "sample", "watch", "status", "history",
        "capabilities", "metrics", "schema", "agent-guide", "self-test",
        "install-cli", "uninstall-cli"
    ]
}
