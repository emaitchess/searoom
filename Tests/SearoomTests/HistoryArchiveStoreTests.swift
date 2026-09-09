import Foundation
import XCTest
@testable import Searoom

final class HistoryArchiveStoreTests: XCTestCase {
    private var workDirectory: URL!

    override func setUpWithError() throws {
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("searoom-history-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDirectory {
            try? FileManager.default.removeItem(at: workDirectory)
        }
    }

    private var archiveURL: URL {
        workDirectory.appendingPathComponent("history.plist")
    }

    private func makeSample(offset: TimeInterval, level: PressureLevel = .nominal) -> SystemSample {
        let data = try! JSONEncoder().encode(SystemSample.placeholder)
        var object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        object["timestamp"] = Date(timeIntervalSinceReferenceDate: 1_000 + offset).timeIntervalSinceReferenceDate
        object["cpuPressureLevel"] = level.rawValue
        return try! JSONDecoder().decode(SystemSample.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func store(limits: HistoryArchiveStore.Limits = .conservative) -> HistoryArchiveStore {
        HistoryArchiveStore(fileURL: archiveURL, limits: limits)
    }

    func testMissingFileReturnsMissing() {
        XCTAssertEqual(store().load(), .missing)
    }

    func testVersionOneArchiveRoundTrips() throws {
        let samples = (0..<3).map { makeSample(offset: Double($0) * 60) }
        XCTAssertTrue(store().save(samples))
        XCTAssertEqual(store().load(), .samples(samples))
    }

    func testArchivesWithoutAvailabilityMetadataDecodeAsLegacyUnknown() throws {
        let samples = [makeSample(offset: 0)]
        XCTAssertTrue(store().save(samples))
        let data = try Data(contentsOf: archiveURL)
        let object = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        var sampleObjects = try XCTUnwrap(object["samples"] as? [[String: Any]])
        XCTAssertEqual(sampleObjects.count, 1)
        sampleObjects[0].removeValue(forKey: "availability")
        sampleObjects[0].removeValue(forKey: "memorySystemPressureLevel")
        var legacy = object
        legacy["samples"] = sampleObjects
        try PropertyListSerialization.data(
            fromPropertyList: legacy,
            format: .binary,
            options: 0
        ).write(to: archiveURL)
        XCTAssertEqual(store().load(), .samples([makeSample(offset: 0)]))
        // And the decoded sample carries the legacy-unknown default.
        guard case .samples(let decoded) = store().load() else { return XCTFail() }
        XCTAssertEqual(decoded[0].availability, .legacyUnknown)
    }

    func testCorruptDataIsDistinguishedFromUnsupported() throws {
        try Data("not a property list".utf8).write(to: archiveURL)
        if case .corrupt = store().load() {} else {
            XCTFail("expected corrupt")
        }

        let object: [String: Any] = ["version": 2, "samples": []]
        try PropertyListSerialization.data(
            fromPropertyList: object, format: .binary, options: 0
        ).write(to: archiveURL)
        if case .unsupported(let version) = store().load() {
            XCTAssertEqual(version, 2)
        } else {
            XCTFail("expected unsupported")
        }
    }

    func testOversizedArchiveIsRejectedBeforeDecoding() throws {
        // A file above the injected size limit is rejected without decode.
        try Data(repeating: 0, count: 1_024).write(to: archiveURL)
        let tinyLimits = HistoryArchiveStore.Limits(maximumFileSizeBytes: 512, maximumSampleCount: 10)
        XCTAssertEqual(store(limits: tinyLimits).load(), .oversized)
    }

    func testSampleCountAboveLimitIsRejected() throws {
        let samples = (0..<20).map { makeSample(offset: Double($0)) }
        XCTAssertTrue(store(limits: .init(maximumFileSizeBytes: 10_485_760, maximumSampleCount: 10)).save(samples))
        let tinyLimits = HistoryArchiveStore.Limits(maximumFileSizeBytes: 10_485_760, maximumSampleCount: 10)
        XCTAssertEqual(store(limits: tinyLimits).load(), .oversized)
    }

    func testSaveIsIdempotentAndReplacesAtomically() throws {
        let first = [makeSample(offset: 0)]
        XCTAssertTrue(store().save(first))
        XCTAssertTrue(store().save(first))
        XCTAssertEqual(store().load(), .samples(first))
    }

    func testClearRemovesTheArchive() throws {
        XCTAssertTrue(store().save([makeSample(offset: 0)]))
        store().clear()
        XCTAssertEqual(store().load(), .missing)
        // Clearing a missing archive is a no-op, not a failure.
        store().clear()
    }

    // MARK: - Status derivation from history

    func testSustainedStatusIsCalculatedBeforeOutputFiltering() {
        // A rising run: nominal 0-120s, elevated from 120s. Filtering to the
        // last sample must not change the sustained duration computed first.
        let run = [
            makeSample(offset: 0),
            makeSample(offset: 60),
            makeSample(offset: 120, level: .elevated),
            makeSample(offset: 180, level: .elevated)
        ]
        let reading = SustainedPressure.duration(in: run)
        XCTAssertEqual(reading?.level, .elevated)
        XCTAssertEqual(reading?.duration ?? 0, 60, accuracy: 0.001)
        XCTAssertFalse(reading?.boundedByHistoryWindow ?? true)

        let filtered = Array(run.dropFirst(2))
        let filteredReading = SustainedPressure.duration(in: filtered)
        XCTAssertEqual(filteredReading?.duration, reading?.duration)
    }

    func testRecentPeakPressureFindsStrongestLevelWithMostRecentTie() {
        let run = [
            makeSample(offset: 0, level: .elevated),
            makeSample(offset: 60, level: .constrained),
            makeSample(offset: 120, level: .nominal),
            makeSample(offset: 180, level: .constrained)
        ]
        let peak = TelemetryDerivedMetrics.recentPeakPressure(in: run)
        XCTAssertEqual(peak?.level, .constrained)
        XCTAssertEqual(
            peak?.timestamp,
            Date(timeIntervalSinceReferenceDate: 1_000 + 180)
        )
    }
}
