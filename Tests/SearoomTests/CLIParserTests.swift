import Foundation
import XCTest
@testable import Searoom

final class CLIParserTests: XCTestCase {
    private func parse(_ arguments: String...) -> CLIParsedInvocation {
        CLIParser.parse(arguments: ["/Applications/Searoom.app/Contents/MacOS/Searoom"] + arguments)
    }

    private func parseSymlink(_ arguments: String...) -> CLIParsedInvocation {
        CLIParser.parse(arguments: ["/opt/homebrew/bin/searoom"] + arguments)
    }

    private func command(of invocation: CLIParsedInvocation) throws -> (CLICommandKind, Bool, Bool) {
        guard case .run(let command, let json, let pretty) = invocation else {
            XCTFail("expected .run, got \(invocation)")
            throw CLIError(exitCode: .softwareError, message: "unexpected invocation")
        }
        return (command, json, pretty)
    }

    private func usage(_ invocation: CLIParsedInvocation) -> CLIError {
        guard case .usageError(let error) = invocation else {
            XCTFail("expected .usageError, got \(invocation)")
            return CLIError(exitCode: .usage, message: "")
        }
        XCTAssertEqual(error.exitCode, .usage)
        return error
    }

    // MARK: - Basename dispatch

    func testNoArgumentsLaunchGUIFromAppBundle() {
        XCTAssertEqual(parse(), .launchGUI)
    }

    func testNoArgumentsPrintHelpThroughSymlink() throws {
        let (command, json, pretty) = try command(of: parseSymlink())
        XCTAssertEqual(command, .help(command: nil))
        XCTAssertFalse(json)
        XCTAssertFalse(pretty)
    }

    func testUnknownArgumentFromAppBundleIsUsageErrorNeverGUI() {
        let error = usage(parse("--bogus"))
        XCTAssertTrue(error.message.contains("--bogus"))
    }

    func testUnknownCommandIsUsageError() {
        usage(parse("bogus"))
    }

    // MARK: - Legacy flags

    func testLegacyDumpSampleFromBothEntryPoints() throws {
        XCTAssertEqual(try command(of: parse("--dump-sample")).0, .legacyDumpSample)
        XCTAssertEqual(try command(of: parseSymlink("--dump-sample")).0, .legacyDumpSample)
    }

    func testLegacySelfTestFromBothEntryPoints() throws {
        XCTAssertEqual(try command(of: parse("--self-test")).0, .selfTest)
        XCTAssertEqual(try command(of: parseSymlink("--self-test")).0, .selfTest)
    }

    func testNewVersionAndHelpFlags() throws {
        XCTAssertEqual(try command(of: parse("--version")).0, .version)
        XCTAssertEqual(try command(of: parseSymlink("--help")).0, .help(command: nil))
    }

    func testLegacyFlagWithExtraArgumentIsUsageError() {
        usage(parse("--dump-sample", "extra"))
    }

    // MARK: - Commands and options

    func testSampleWithIntervalBounds() throws {
        XCTAssertEqual(try command(of: parse("sample")).0, .sample(interval: nil))
        XCTAssertEqual(try command(of: parse("sample", "--interval", "1")).0, .sample(interval: 1))
        XCTAssertEqual(try command(of: parse("sample", "--interval", "10", "--pretty")).0, .sample(interval: 10))
        XCTAssertTrue(try command(of: parse("sample", "--pretty")).2)
    }

    func testIntervalOutsideSupportedRangeIsRejected() {
        usage(parse("sample", "--interval", "11"))
        usage(parse("sample", "--interval", "0"))
        usage(parse("sample", "--interval", "-2"))
        usage(parse("sample", "--interval", "2.5"))
        usage(parse("sample", "--interval", "nan"))
        usage(parse("sample", "--interval", "inf"))
        usage(parse("sample", "--interval", "999999999999999999999"))
    }

    func testWatchWithCountAndInterval() throws {
        XCTAssertEqual(try command(of: parse("watch", "--interval", "5", "--count", "3")).0, .watch(interval: 5, count: 3))
    }

    func testWatchRejectsPrettyAndJSONL() {
        usage(parse("watch", "--pretty"))
        usage(parse("watch", "--jsonl"))
    }

    func testCountAndLimitRequirePositiveIntegers() {
        usage(parse("watch", "--count", "0"))
        usage(parse("history", "--limit", "-1"))
        usage(parse("history", "--limit", "abc"))
        usage(parse("watch", "--count", "1.5"))
    }

    func testDuplicateOptionsAreRejected() {
        usage(parse("sample", "--interval", "2", "--interval", "3"))
        usage(parse("history", "--limit", "1", "--limit", "2"))
        usage(parse("history", "--jsonl", "--jsonl"))
    }

    func testMissingOptionValueIsRejected() {
        usage(parse("sample", "--interval"))
        usage(parse("watch", "--count"))
        usage(parse("history", "--since"))
    }

    func testUnknownOptionIsRejected() {
        usage(parse("sample", "--bogus"))
        usage(parse("version", "--pretty"))
    }

    func testTrailingArgumentIsRejected() {
        usage(parse("version", "extra"))
        usage(parse("schema", "extra"))
        usage(parse("sample", "extra"))
    }

    func testHelpWithCommandTopic() throws {
        XCTAssertEqual(try command(of: parse("help", "sample")).0, .help(command: "sample"))
        XCTAssertEqual(try command(of: parse("help", "--json", "history")).0, .help(command: "history"))
        usage(parse("help", "bogus"))
    }

    func testMetricsWithMetricIdentifier() throws {
        XCTAssertEqual(try command(of: parse("metrics", "cpu.usageFraction")).0, .metrics(metric: "cpu.usageFraction"))
        usage(parse("metrics", "cpu.usageFraction", "extra"))
    }

    // MARK: - Time bounds

    func testRelativeDurationsParse() throws {
        guard case .history(let filter, _) = try command(of: parse("history", "--since", "30m")).0 else {
            return XCTFail("expected history")
        }
        XCTAssertEqual(filter.since, .relative(seconds: 1_800, token: "30m"))
    }

    func testRelativeDurationUnits() {
        XCTAssertEqual(CLITimeBound.parseRelative("45"), 45)
        XCTAssertEqual(CLITimeBound.parseRelative("10s"), 10)
        XCTAssertEqual(CLITimeBound.parseRelative("30m"), 1_800)
        XCTAssertEqual(CLITimeBound.parseRelative("3h"), 10_800)
        XCTAssertEqual(CLITimeBound.parseRelative("2d"), 172_800)
        XCTAssertNil(CLITimeBound.parseRelative(""))
        XCTAssertNil(CLITimeBound.parseRelative("abc"))
        XCTAssertNil(CLITimeBound.parseRelative("-5m"))
        XCTAssertNil(CLITimeBound.parseRelative("nanm"))
    }

    func testRFC3339TimestampsParseWithAndWithoutFraction() {
        XCTAssertNotNil(CLITimeBound.parse("2026-09-06T12:34:56Z"))
        XCTAssertNotNil(CLITimeBound.parse("2026-09-06T12:34:56.123Z"))
        XCTAssertNil(CLITimeBound.parse("2026-09-06"))
        XCTAssertNil(CLITimeBound.parse("not a time"))
    }

    func testReversedTimeRangeIsRejectedAtResolution() {
        guard case .history(let filter, _) = try! command(of: parse(
            "history",
            "--since", "2026-01-02T00:00:00Z",
            "--until", "2026-01-01T00:00:00Z"
        )).0 else { return XCTFail("expected history") }
        XCTAssertThrowsError(try filter.resolve(now: Date())) { error in
            XCTAssertEqual((error as? CLIError)?.exitCode, .usage)
        }
    }

    func testFilterSinceInclusiveUntilExclusiveAndLimitNewest() {
        func sample(_ offset: TimeInterval) -> SystemSample {
            SystemSample.placeholder.timestamp(for: Date(timeIntervalSinceReferenceDate: 1_000 + offset))
        }

        let samples: [SystemSample] = (0..<5).map { sample(Double($0)) }
        let filter = HistoryFilter(
            since: .absolute(Date(timeIntervalSinceReferenceDate: 1_001)),
            until: .absolute(Date(timeIntervalSinceReferenceDate: 1_004)),
            limit: 2
        )
        let resolved = try! filter.resolve(now: Date(timeIntervalSinceReferenceDate: 2_000))
        let matching = filter.apply(samples, to: resolved)
        // since (1_001) inclusive, until (1_004) exclusive, newest two retained.
        let offsets = matching.map { $0.timestamp.timeIntervalSinceReferenceDate }
        XCTAssertEqual(offsets, [1_002, 1_003])
    }

    // MARK: - history --jsonl

    /// `--jsonl` was parsed, validated, and then dropped on the floor: the
    /// runner read the shared `--json` flag instead, which history does not
    /// accept, so the flag could never be true and `history --jsonl` silently
    /// returned the envelope document.
    func testHistoryCarriesJSONLinesThroughToTheCommand() throws {
        guard case .history(_, let jsonl) = try command(of: parse("history", "--jsonl")).0 else {
            return XCTFail("expected a history command")
        }
        XCTAssertTrue(jsonl)
    }

    func testHistoryWithoutTheFlagRequestsTheEnvelope() throws {
        guard case .history(_, let jsonl) = try command(of: parse("history")).0 else {
            return XCTFail("expected a history command")
        }
        XCTAssertFalse(jsonl)
    }

    func testHistoryRejectsTheSharedJSONFlag() {
        let error = usage(parse("history", "--json"))
        XCTAssertEqual(error.message, "option --json is not valid for this command")
    }

    // MARK: - Shorthand options

    /// Every shorthand must resolve to exactly the long form it documents, in
    /// the same parse the long form produces.
    func testStandaloneShorthandHelpAndVersion() throws {
        XCTAssertEqual(try command(of: parse("-h")).0, .help(command: nil))
        XCTAssertEqual(try command(of: parseSymlink("-h")).0, .help(command: nil))
        XCTAssertEqual(try command(of: parse("-v")).0, .version)
        XCTAssertEqual(try command(of: parseSymlink("-v")).0, .version)
    }

    func testEveryShorthandResolvesToItsLongForm() throws {
        XCTAssertEqual(try command(of: parse("sample", "-i", "4", "-p")).0, .sample(interval: 4))
        XCTAssertTrue(try command(of: parse("sample", "-i", "4", "-p")).2)
        XCTAssertEqual(try command(of: parse("watch", "-i", "1", "-c", "2")).0, .watch(interval: 1, count: 2))
        XCTAssertTrue(try command(of: parse("help", "-j")).1)
        XCTAssertTrue(try command(of: parse("version", "-j")).1)
        XCTAssertTrue(try command(of: parse("capabilities", "-p")).2)

        guard case .history(let filter, let jsonl) = try command(
            of: parse("history", "-s", "30m", "-u", "15m", "-n", "5", "-l")
        ).0 else {
            return XCTFail("expected a history command")
        }
        XCTAssertEqual(filter.since, .relative(seconds: 1_800, token: "30m"))
        XCTAssertEqual(filter.until, .relative(seconds: 900, token: "15m"))
        XCTAssertEqual(filter.limit, 5)
        XCTAssertTrue(jsonl)
    }

    func testShorthandErrorsNameTheCanonicalOption() {
        XCTAssertEqual(usage(parse("sample", "-i")).message, "--interval requires a value")
        XCTAssertEqual(usage(parse("sample", "-i", "2", "-i", "3")).message, "duplicate option --interval")
        XCTAssertEqual(usage(parse("schema", "-j")).message, "option --json is not valid for this command")
        XCTAssertEqual(
            usage(parse("watch", "-c", "0")).message,
            "0 is not a positive whole number for --count"
        )
        XCTAssertEqual(
            usage(parse("history", "-s", "bogus")).message,
            "bogus is not an RFC 3339 timestamp or relative duration for --since"
        )
        XCTAssertEqual(usage(parse("sample", "-v")).message, "option --version is not valid for this command")
    }

    /// `searoom COMMAND -h` prints that command's reference and wins over
    /// validating the rest of the line, in both flag spellings.
    func testPerCommandHelpWinsOverValidation() throws {
        XCTAssertEqual(try command(of: parse("sample", "-h")).0, .help(command: "sample"))
        XCTAssertEqual(try command(of: parse("sample", "--help")).0, .help(command: "sample"))
        XCTAssertEqual(try command(of: parse("history", "--since", "bogus", "-h")).0, .help(command: "history"))
        XCTAssertEqual(try command(of: parse("watch", "-p", "-h")).0, .help(command: "watch"))
        XCTAssertEqual(try command(of: parse("help", "-h")).0, .help(command: nil))
        XCTAssertEqual(try command(of: parse("help", "-h", "--json")).0, .help(command: nil))
    }

    func testPerCommandHelpRequiresAKnownCommand() {
        usage(parse("bogus", "-h"))
        usage(parse("-h", "extra"))
    }

    /// The bundled catalog advertises one shorthand per option argument and
    /// none for positional arguments, and every advertised shorthand parses.
    /// `-h` and `-v` are deliberately absent: they are standalone flags
    /// documented in the usage text, not arguments of the help/version
    /// commands, so the catalog has nothing to attach them to.
    func testCatalogShorthandsMatchTheParserTable() throws {
        let catalog = CLICommandCatalog.make()
        let shorthands = CLIParser.shorthands
        var seen: Set<String> = []
        for command in catalog.commands {
            for argument in command.arguments {
                guard let shorthand = argument.shorthand else { continue }
                XCTAssertEqual(shorthands[shorthand], argument.name, command.name)
                seen.insert(shorthand)
            }
        }
        XCTAssertEqual(seen.sorted(), ["-c", "-i", "-j", "-l", "-n", "-p", "-s", "-u"])
        XCTAssertEqual(shorthands["-h"], "--help")
        XCTAssertEqual(shorthands["-v"], "--version")
        // Positional arguments never carry a shorthand.
        XCTAssertNil(catalog.commands.first { $0.name == "help" }?.arguments.first { $0.name == "COMMAND" }?.shorthand)
        XCTAssertNil(catalog.commands.first { $0.name == "metrics" }?.arguments.first { $0.name == "METRIC" }?.shorthand)
    }

    /// The catalog document stays valid with the additive `shorthand` field:
    /// the long option carries its single-letter form, and a positional keeps
    /// the explicit `null` the v1 null-encoding contract requires.
    func testCatalogArgumentShorthandEncoding() throws {
        let document = HelpCatalogDocumentV1(
            catalog: CLICommandCatalog.make(),
            version: CLIVersionInfo(searoomVersion: "0.0.0", buildNumber: "0", macosFloor: "14.0"),
            generatedAt: Date(timeIntervalSinceReferenceDate: 0)
        )
        let object = try JSONSerialization.jsonObject(
            with: TelemetryOutputV1.encode(document, pretty: false)
        ) as! [String: Any]
        let catalog = try XCTUnwrap(object["catalog"] as? [String: Any], "catalog missing")
        let commands = try XCTUnwrap(catalog["commands"] as? [[String: Any]])

        let sample = try XCTUnwrap(commands.first { $0["name"] as? String == "sample" })
        let sampleArguments = try XCTUnwrap(sample["arguments"] as? [[String: Any]])
        let interval = try XCTUnwrap(sampleArguments.first { $0["name"] as? String == "--interval" })
        XCTAssertEqual(interval["shorthand"] as? String, "-i")

        let help = try XCTUnwrap(commands.first { $0["name"] as? String == "help" })
        let helpArguments = try XCTUnwrap(help["arguments"] as? [[String: Any]])
        let commandPositional = try XCTUnwrap(helpArguments.first { $0["name"] as? String == "COMMAND" })
        XCTAssertTrue(
            commandPositional["shorthand"] is NSNull,
            "positional arguments encode an explicit null shorthand"
        )
    }
}

private extension SystemSample {
    func timestamp(for date: Date) -> SystemSample {
        // Samples differ only by timestamp in filter tests.
        let data = try! JSONEncoder().encode(self)
        var object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        object["timestamp"] = date.timeIntervalSinceReferenceDate
        return try! JSONDecoder().decode(SystemSample.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
