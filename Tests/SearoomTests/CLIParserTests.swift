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
