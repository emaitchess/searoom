import Foundation
import XCTest
@testable import Searoom

final class SearoomTests: XCTestCase {
    func testRingBufferRetainsNewestValuesInOrder() {
        var buffer = RingBuffer<Int>()
        for value in 0..<10 { buffer.append(value, maximumCount: 4) }

        XCTAssertEqual(buffer.snapshot(), [6, 7, 8, 9])
        XCTAssertEqual(buffer[0], 6)
        XCTAssertEqual(buffer[3], 9)

        buffer.removeFirst(while: { $0 < 8 }, keepingAtLeast: 1)
        XCTAssertEqual(buffer.snapshot(), [8, 9])

        buffer.trim(to: 1)
        XCTAssertEqual(buffer.snapshot(), [9])
        buffer.removeAll(keepingCapacity: true)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testRingBufferMatchesArrayAcrossChangingCapacity() {
        var buffer = RingBuffer<Int>()
        var reference: [Int] = []
        let capacities = [1, 7, 3, 16, 2, 8]

        for value in 0..<150 {
            let capacity = capacities[(value / 5) % capacities.count]
            buffer.append(value, maximumCount: capacity)
            reference.append(value)
            reference = Array(reference.suffix(capacity))
            XCTAssertEqual(buffer.snapshot(), reference, "Mismatch after appending \(value)")
        }
    }

    func testRingBufferReplacementAndZeroCapacityAreBounded() {
        var buffer = RingBuffer<Int>()
        buffer.replaceContents(0..<10, maximumCount: 4)
        XCTAssertEqual(buffer.snapshot(), [6, 7, 8, 9])

        buffer.append(10, maximumCount: 0)
        XCTAssertTrue(buffer.isEmpty)

        buffer.append(11, maximumCount: 2)
        XCTAssertEqual(buffer.snapshot(), [11])
    }

    func testTrendRefreshPolicyThrottlesAndResetsFromForcedRefresh() {
        var policy = DashboardTrendRefreshPolicy()
        let start = ContinuousClock().now

        XCTAssertTrue(policy.shouldRefresh(at: start))
        XCTAssertFalse(policy.shouldRefresh(at: start.advanced(by: .milliseconds(4_999))))
        XCTAssertTrue(policy.shouldRefresh(at: start.advanced(by: .seconds(5))))
        XCTAssertFalse(policy.shouldRefresh(at: start.advanced(by: .seconds(6))))
        XCTAssertTrue(policy.shouldRefresh(at: start.advanced(by: .seconds(6)), force: true))
        XCTAssertFalse(policy.shouldRefresh(at: start.advanced(by: .milliseconds(10_999))))
        XCTAssertTrue(policy.shouldRefresh(at: start.advanced(by: .seconds(11))))

        policy.reset()
        XCTAssertTrue(policy.shouldRefresh(at: start.advanced(by: .seconds(11))))
    }

    func testTrendSampleLocatorReturnsNearestRealSample() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let timestamps = [0.0, 2, 7, 11].map(start.addingTimeInterval)
        func nearest(_ offset: TimeInterval) -> Int? {
            DashboardTrendSampleLocator.nearestIndex(
                to: start.addingTimeInterval(offset),
                count: timestamps.count,
                timestampAt: { timestamps[$0] }
            )
        }

        XCTAssertNil(DashboardTrendSampleLocator.nearestIndex(
            to: start,
            count: 0,
            timestampAt: { _ in start }
        ))
        XCTAssertEqual(nearest(-10), 0)
        XCTAssertEqual(nearest(3), 1)
        XCTAssertEqual(nearest(4.5), 1, "Ties should select the earlier real sample")
        XCTAssertEqual(nearest(6), 2)
        XCTAssertEqual(nearest(20), 3)
    }

    func testPressureThresholds() {
        XCTAssertEqual(PressureLevel.from(utilization: 0.25), .nominal)
        XCTAssertEqual(PressureLevel.from(utilization: 0.70), .elevated)
        XCTAssertEqual(PressureLevel.from(utilization: 0.85), .constrained)
        XCTAssertEqual(PressureLevel.from(utilization: 0.95), .critical)
        XCTAssertEqual(PressureLevel.nominal.compactLabel, "OK")
        XCTAssertEqual(PressureLevel.constrained.compactLabel, "TIGHT")
        XCTAssertEqual(PressureLevel.unavailable.compactLabel, "N/A")
    }

    func testOverallPressureUsesHighestAvailableSignal() throws {
        XCTAssertEqual(
            try sampleWithPressures(
                cpu: .unavailable,
                memory: .unavailable,
                thermal: .unavailable,
                gpu: .unavailable
            ).overallPressureLevel,
            .unavailable
        )
        XCTAssertEqual(
            try sampleWithPressures(
                cpu: .nominal,
                memory: .critical,
                thermal: .elevated,
                gpu: .unavailable
            ).overallPressureLevel,
            .critical
        )
    }

    func testMenuBarPresetsRoundTrip() throws {
        for preset in MenuBarPreset.allCases {
            let encoded = try JSONEncoder().encode(preset)
            XCTAssertEqual(try JSONDecoder().decode(MenuBarPreset.self, from: encoded), preset)
        }
    }

    func testInvalidSettingsFallBackToBoundedDefaults() throws {
        let data = Data("{\"sampleInterval\":0,\"historyMinutes\":999999}".utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.sampleInterval, 2)
        XCTAssertEqual(settings.historyMinutes, 30)

        let constructed = AppSettings(sampleInterval: .infinity, historyMinutes: -1)
        XCTAssertEqual(constructed.sampleInterval, 2)
        XCTAssertEqual(constructed.historyMinutes, 30)
    }

    func testSupportedSettingsValuesArePreserved() {
        for interval in AppSettings.supportedSampleIntervals {
            for historyMinutes in AppSettings.supportedHistoryMinutes {
                let settings = AppSettings(
                    sampleInterval: interval,
                    historyMinutes: historyMinutes
                )
                XCTAssertEqual(settings.sampleInterval, interval)
                XCTAssertEqual(settings.historyMinutes, historyMinutes)
            }
        }
    }

    func testCustomMenuBarMetricsRoundTrip() throws {
        for metric in MenuBarMetric.allCases {
            let encoded = try JSONEncoder().encode(metric)
            XCTAssertEqual(try JSONDecoder().decode(MenuBarMetric.self, from: encoded), metric)
        }
    }

    func testShortcutRoundTrip() throws {
        let shortcut = GlobalShortcut(
            keyCode: 4,
            modifiers: [.command, .option, .shift],
            keyLabel: "H"
        )
        var settings = AppSettings()
        settings.globalShortcut = shortcut

        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: encoded)

        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.globalShortcut?.displayName, "⌥⇧⌘H")
    }

    func testShortcutPrimaryModifierRequirement() {
        XCTAssertTrue(ShortcutModifiers.command.hasPrimaryModifier)
        XCTAssertTrue(ShortcutModifiers.option.hasPrimaryModifier)
        XCTAssertTrue(ShortcutModifiers.control.hasPrimaryModifier)
        XCTAssertTrue(ShortcutModifiers([.command, .shift]).hasPrimaryModifier)
        XCTAssertFalse(ShortcutModifiers.shift.hasPrimaryModifier)
        XCTAssertFalse(ShortcutModifiers().hasPrimaryModifier)
    }

    func testCustomMenuBarMetricsRoundTripAndMigration() throws {
        var settings = AppSettings()
        settings.menuBarPreset = .custom
        settings.customMenuBarMetrics = [.cpuUsage, .memoryUsed, .temperature]

        let encoded = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: encoded), settings)

        let legacy = Data("{\"sampleInterval\":5}".utf8)
        let migrated = try JSONDecoder().decode(AppSettings.self, from: legacy)
        XCTAssertEqual(migrated.customMenuBarMetrics, MenuBarMetric.defaults)

        let futureMetric = Data(
            "{\"customMenuBarMetrics\":[\"cpuUsage\",\"futureMetric\"]}".utf8
        )
        let forwardCompatible = try JSONDecoder().decode(AppSettings.self, from: futureMetric)
        XCTAssertEqual(forwardCompatible.customMenuBarMetrics, [.cpuUsage])
    }

    func testLaunchAtLoginPromptStateRoundTripAndMigration() throws {
        var settings = AppSettings()
        XCTAssertFalse(settings.hasCompletedLaunchAtLoginPrompt)

        settings.hasCompletedLaunchAtLoginPrompt = true
        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: encoded)
        XCTAssertTrue(decoded.hasCompletedLaunchAtLoginPrompt)

        let legacy = try JSONDecoder().decode(
            AppSettings.self,
            from: Data("{\"sampleInterval\":5}".utf8)
        )
        XCTAssertTrue(legacy.hasCompletedLaunchAtLoginPrompt)
    }

    func testLaunchAtLoginPromptPolicy() {
        XCTAssertTrue(LaunchAtLoginPromptPolicy.shouldPrompt(
            isPackaged: true,
            hasCompleted: false,
            serviceIsNotRegistered: true
        ))
        XCTAssertFalse(LaunchAtLoginPromptPolicy.shouldPrompt(
            isPackaged: false,
            hasCompleted: false,
            serviceIsNotRegistered: true
        ))
        XCTAssertFalse(LaunchAtLoginPromptPolicy.shouldPrompt(
            isPackaged: true,
            hasCompleted: true,
            serviceIsNotRegistered: true
        ))
        XCTAssertFalse(LaunchAtLoginPromptPolicy.shouldPrompt(
            isPackaged: true,
            hasCompleted: false,
            serviceIsNotRegistered: false
        ))
    }

    func testCustomMenuBarMetricsAreBoundedAndUnique() {
        XCTAssertEqual(MenuBarMetric.normalized([]), MenuBarMetric.defaults)
        XCTAssertEqual(
            MenuBarMetric.normalized([.cpuUsage, .cpuUsage, .temperature, .gpuUsage]),
            [.cpuUsage, .temperature, .gpuUsage]
        )
        XCTAssertEqual(
            MenuBarMetric.normalized([.cpuUsage, .memoryUsed, .temperature, .gpuUsage]),
            [.cpuUsage, .memoryUsed, .temperature]
        )
    }

    func testMetricFormatting() {
        XCTAssertEqual(MetricFormat.compactBytes(16 * 1_073_741_824), "16G")
        XCTAssertEqual(MetricFormat.percent(0.427), "43%")
        XCTAssertEqual(MetricFormat.unboundedPercent(1.25), "125%")
        XCTAssertEqual(MetricFormat.fixedField("8%", columns: 4), "  8%")
        XCTAssertEqual(MetricFormat.fixedField("10%", columns: 4), " 10%")
        XCTAssertEqual(
            MetricFormat.fixedField("8%", columns: 4).count,
            MetricFormat.fixedField("10%", columns: 4).count
        )
        XCTAssertEqual(MetricFormat.fixedLabel("BAT", columns: 4), "BAT ")
        XCTAssertEqual(MetricFormat.fixedField("TOO-LONG", columns: 4), "TOO-LONG")
        XCTAssertEqual(MetricFormat.temperature(nil), "N/A")
        XCTAssertEqual(MetricFormat.uptime(90_061), "01D 01H")
        XCTAssertEqual(MetricFormat.fanActivity([]), "N/A")
        XCTAssertEqual(
            MetricFormat.fanActivity([FanSample(name: "FAN 1", rpm: 2_314)]),
            "2314 RPM"
        )
        XCTAssertEqual(
            MetricFormat.fanActivity([
                FanSample(name: "FAN 1", rpm: 2_314),
                FanSample(name: "FAN 2", rpm: 2_500)
            ]),
            "F1 2314 · F2 2500"
        )
    }

    func testOlderSampleReceivesDefaultsForNewMetrics() throws {
        let encoded = try JSONEncoder().encode(SystemSample.placeholder)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "swapInPerSecond")
        object.removeValue(forKey: "swapOutPerSecond")
        object.removeValue(forKey: "isLowPowerModeEnabled")

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(SystemSample.self, from: legacyData)

        XCTAssertEqual(decoded.swapInPerSecond, 0)
        XCTAssertEqual(decoded.swapOutPerSecond, 0)
        XCTAssertFalse(decoded.isLowPowerModeEnabled)
    }

    func testBatteryTemperatureNormalization() {
        XCTAssertEqual(BatteryCollector.normalizeTemperature(2_759) ?? .nan, 27.59, accuracy: 0.001)
        XCTAssertEqual(BatteryCollector.normalizeTemperature(31) ?? .nan, 31, accuracy: 0.001)
        XCTAssertEqual(BatteryCollector.normalizeTemperature(-4_000) ?? .nan, -40, accuracy: 0.001)
        XCTAssertEqual(BatteryCollector.normalizeTemperature(10_000) ?? .nan, 100, accuracy: 0.001)
        XCTAssertNil(BatteryCollector.normalizeTemperature(.nan))
        XCTAssertNil(BatteryCollector.normalizeTemperature(10_001))
        XCTAssertNil(BatteryCollector.normalizeTemperature(50_000))
    }

    func testSMCSensorDecoderRegression() {
        XCTAssertTrue(ThermalCollector.sensorDecoderSelfTest())
    }

    func testCollectorReturnsBoundedValues() {
        let collector = SystemMetricsCollector()
        _ = collector.collect()
        let sample = collector.collect()

        XCTAssertGreaterThan(sample.memoryTotal, 0)
        XCTAssertLessThanOrEqual(sample.memoryUsed, sample.memoryTotal)
        XCTAssertGreaterThan(sample.uptime, 0)
        XCTAssertTrue((0...1).contains(sample.cpuUsage))
        XCTAssertTrue((0...1).contains(sample.memoryPressure))
        XCTAssertGreaterThanOrEqual(sample.swapInPerSecond, 0)
        XCTAssertGreaterThanOrEqual(sample.swapOutPerSecond, 0)
        XCTAssertGreaterThan(sample.processMemoryBytes, 0)
    }

    private func sampleWithPressures(
        cpu: PressureLevel,
        memory: PressureLevel,
        thermal: PressureLevel,
        gpu: PressureLevel
    ) throws -> SystemSample {
        let encoded = try JSONEncoder().encode(SystemSample.placeholder)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["cpuPressureLevel"] = cpu.rawValue
        object["memoryPressureLevel"] = memory.rawValue
        object["thermalPressureLevel"] = thermal.rawValue
        object["gpuPressureLevel"] = gpu.rawValue
        return try JSONDecoder().decode(
            SystemSample.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }
}
