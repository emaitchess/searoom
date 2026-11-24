import CSearoomSensors
import Foundation
import XCTest
@testable import Searoom

final class LiveReadingsTests: XCTestCase {
    private typealias Ticks = CoreCollector.Ticks
    private typealias Level = CoreCollector.PerformanceLevel

    // MARK: - Per-core usage

    func testCoreUsageIsTheBusyShareOfElapsedTicks() {
        let before = Ticks(user: 100, system: 50, nice: 10, idle: 1_000)
        let after = Ticks(user: 150, system: 75, nice: 35, idle: 1_100)
        XCTAssertEqual(CoreCollector.usage(from: before, to: after), 0.5)
    }

    func testCoreUsageSurvivesCounterWrap() {
        let before = Ticks(user: UInt32.max - 5, system: 0, nice: 0, idle: 0)
        let after = Ticks(user: 4, system: 0, nice: 0, idle: 30)
        XCTAssertEqual(CoreCollector.usage(from: before, to: after), 0.25)
    }

    func testACoreWithNoElapsedTicksHasNoReading() {
        let ticks = Ticks(user: 1, system: 2, nice: 3, idle: 4)
        XCTAssertNil(CoreCollector.usage(from: ticks, to: ticks))
    }

    func testFirstCoreReadIsWarmingUpWithNoUsage() {
        let current = [Ticks(user: 1, system: 0, nice: 0, idle: 9)]
        let reading = CoreCollector.reading(current: current, previous: nil, kinds: ["efficiency"])
        XCTAssertEqual(reading.availability, .warmingUp)
        XCTAssertEqual(reading.cores, [CoreReading(index: 0, kind: "efficiency", usage: nil)])
    }

    func testAChangedCoreCountRebaselines() {
        let one = [Ticks(user: 1, system: 0, nice: 0, idle: 9)]
        let reading = CoreCollector.reading(current: one + one, previous: one, kinds: [nil, nil])
        XCTAssertEqual(reading.availability, .warmingUp)
        XCTAssertTrue(reading.cores.allSatisfy { $0.usage == nil })
    }

    // MARK: - Core kinds

    private func clusters(_ letters: String) -> [Int: String] {
        Dictionary(uniqueKeysWithValues: letters.enumerated().map { ($0.offset, String($0.element)) })
    }

    func testKindsOnAnM4Layout() {
        XCTAssertEqual(
            CoreCollector.kinds(
                levels: [Level(name: "performance", coreCount: 4), Level(name: "efficiency", coreCount: 6)],
                clusterTypes: clusters("EEEEEEPPPP"),
                coreCount: 10
            ),
            Array(repeating: "efficiency", count: 6) + Array(repeating: "performance", count: 4)
        )
    }

    func testKindsOnAnM5ProLayoutUseTheKernelsNamesRatherThanTheLetters() {
        XCTAssertEqual(
            CoreCollector.kinds(
                levels: [Level(name: "super", coreCount: 5), Level(name: "performance", coreCount: 10)],
                clusterTypes: clusters("MMMMMMMMMMPPPPP"),
                coreCount: 15
            ),
            Array(repeating: "performance", count: 10) + Array(repeating: "super", count: 5)
        )
    }

    func testKindsAreUnknownWhenTheSourcesDisagree() {
        let levels = [Level(name: "performance", coreCount: 4), Level(name: "efficiency", coreCount: 6)]
        let unknown = [String?](repeating: nil, count: 10)
        // Counts differ between the kernel and the device tree.
        XCTAssertEqual(
            CoreCollector.kinds(levels: levels, clusterTypes: clusters("EEEEEPPPPP"), coreCount: 10),
            unknown
        )
        // A cluster letter this build does not know.
        XCTAssertEqual(
            CoreCollector.kinds(levels: levels, clusterTypes: clusters("EEEEEEXXXX"), coreCount: 10),
            unknown
        )
        // A virtual machine publishes no cluster types.
        XCTAssertEqual(CoreCollector.kinds(levels: levels, clusterTypes: [:], coreCount: 10), unknown)
        // A hole in the numbering.
        var holed = clusters("EEEEEEPPPP")
        holed[3] = nil
        holed[99] = "E"
        XCTAssertEqual(CoreCollector.kinds(levels: levels, clusterTypes: holed, coreCount: 10), unknown)
        // No perflevel names.
        XCTAssertEqual(
            CoreCollector.kinds(levels: [], clusterTypes: clusters("EEEEEEPPPP"), coreCount: 10),
            unknown
        )
    }

    func testLiveReadingsAreBoundedOnThisMac() {
        let collector = LiveReadingsCollector()
        _ = collector.read()
        Thread.sleep(forTimeInterval: 0.2)
        let live = collector.read()
        XCTAssertEqual(live.cores.map(\.index), Array(live.cores.indices))
        for usage in live.cores.compactMap(\.usage) { XCTAssertTrue((0...1).contains(usage)) }
        if let watts = live.systemWatts { XCTAssertTrue(watts > 0 && watts <= 2_000) }
        if let celsius = live.gpuTemperatureCelsius { XCTAssertTrue((10...125).contains(celsius)) }
    }

    // MARK: - GPU temperature

    func testGPUMeanLeavesOutTheReadingsAnM4PublishesWhileItsGPUIsOff() {
        // Every Tg key reads -4.5 or 0.8 then, and neither is a temperature.
        XCTAssertNil(gpuMean([-4.5, 0.8, -4.5, 0.8]))
        XCTAssertEqual(gpuMean([-4.5, 40, 0.8, 42]) ?? 0, 41, accuracy: 0.001)
        // A pair under load, 5.3 degrees apart: the mean sits between them.
        XCTAssertEqual(gpuMean([54.38, 59.68]) ?? 0, 57.03, accuracy: 0.001)
    }

    func testGPUMeanIsUnavailableWithoutSensors() {
        XCTAssertNil(gpuMean([]))
        XCTAssertNil(gpuMean([.nan, .infinity, 900]))
    }

    private func gpuMean(_ readings: [Double]) -> Double? {
        var average = 0.0
        return readings.withUnsafeBufferPointer {
            SRAverageTemperatures($0.baseAddress, Int32($0.count), &average) ? average : nil
        }
    }

    // MARK: - Fans

    func testFanLimitsAreNotPersisted() throws {
        let fan = FanSample(
            name: "FAN 1",
            rpm: 1_000,
            limits: FanSample.Limits(minimumRPM: 1_000, maximumRPM: 4_900)
        )
        let data = try PropertyListEncoder().encode(fan)
        let object = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ["name", "rpm"])
        XCTAssertNil(try PropertyListDecoder().decode(FanSample.self, from: data).limits)
    }
}
