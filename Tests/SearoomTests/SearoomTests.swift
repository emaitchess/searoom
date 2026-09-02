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

    func testPrimaryTrendHoverMetricsStaySynchronized() {
        let primaryMetrics: [DashboardTrendMetric] = [
            .cpu, .memory, .gpu, .thermal, .gpuMemory, .diskUsed
        ]
        for metric in primaryMetrics {
            XCTAssertEqual(metric.synchronizedMetrics, primaryMetrics)
        }
        XCTAssertEqual(DashboardTrendMetric.network.synchronizedMetrics, [.network])
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

    // One row per preset that used to exist. An upgrade must keep showing what
    // it showed before, and this is the only thing standing between a user and
    // a silently rearranged menu bar.
    func testEveryLegacyPresetMigratesToItsMetrics() throws {
        let expected: [String: [MenuBarMetric]] = [
            "balanced": [.cpuUsage, .memoryUsed],
            "reserve": [.memoryFree, .swapUsed],
            "pressure": [.memoryPressure, .thermalPressure],
            "llm": [.memoryUsed, .temperature, .gpuMemory],
            "compute": [.cpuUsage, .gpuUsage],
            "network": [.networkDownload, .networkUpload],
            "disk": [.diskRead, .diskWrite],
            "swap": [.swapIn, .swapOut],
            "thermal": [.temperature, .fan],
            "power": [.power],
            "minimal": []
        ]
        for (preset, metrics) in expected {
            let archive = Data("{\"menuBarPreset\":\"\(preset)\"}".utf8)
            let decoded = try JSONDecoder().decode(AppSettings.self, from: archive)
            XCTAssertEqual(decoded.menuBarMetrics, metrics, "\(preset) migrated wrongly")
        }

        // Custom carried its own list, which survives intact.
        let custom = Data(
            "{\"menuBarPreset\":\"custom\",\"customMenuBarMetrics\":[\"gpuUsage\",\"uptime\"]}".utf8
        )
        XCTAssertEqual(
            try JSONDecoder().decode(AppSettings.self, from: custom).menuBarMetrics,
            [.gpuUsage, .uptime]
        )

        // A preset a later build invented falls back to any stored selection,
        // and to the defaults when there is none.
        let unknown = Data("{\"menuBarPreset\":\"holographic\"}".utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(AppSettings.self, from: unknown).menuBarMetrics,
            MenuBarMetric.defaults
        )
    }

    func testMenuBarMetricSelectionIsCappedAndMayBeEmpty() throws {
        XCTAssertEqual(MenuBarMetric.maximumCount, 5)
        let tooMany: [MenuBarMetric] = [
            .cpuUsage, .memoryUsed, .temperature, .gpuUsage, .diskFree, .uptime
        ]
        XCTAssertEqual(MenuBarMetric.normalized(tooMany).count, 5)
        XCTAssertEqual(MenuBarMetric.normalized(tooMany), Array(tooMany.prefix(5)))
        XCTAssertEqual(MenuBarMetric.normalized([.cpuUsage, .cpuUsage]), [.cpuUsage])

        // Empty is a deliberate selection meaning the mark-only item, so it
        // must survive rather than reverting to the defaults.
        XCTAssertEqual(MenuBarMetric.normalized([]), [])
        var settings = AppSettings()
        settings.menuBarMetrics = []
        let round = try JSONDecoder().decode(
            AppSettings.self,
            from: try JSONEncoder().encode(settings)
        )
        XCTAssertEqual(round.menuBarMetrics, [])

        // A missing key is a different case entirely and still gives defaults.
        let fresh = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(fresh.menuBarMetrics, MenuBarMetric.defaults)
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

    func testMenuBarMetricsRoundTripAndMigration() throws {
        var settings = AppSettings()
        settings.menuBarMetrics = [.cpuUsage, .memoryUsed, .temperature, .gpuUsage, .diskFree]

        let encoded = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: encoded), settings)

        let legacy = Data("{\"sampleInterval\":5}".utf8)
        let migrated = try JSONDecoder().decode(AppSettings.self, from: legacy)
        XCTAssertEqual(migrated.menuBarMetrics, MenuBarMetric.defaults)

        let futureMetric = Data(
            "{\"menuBarMetrics\":[\"cpuUsage\",\"futureMetric\"]}".utf8
        )
        let forwardCompatible = try JSONDecoder().decode(AppSettings.self, from: futureMetric)
        XCTAssertEqual(forwardCompatible.menuBarMetrics, [.cpuUsage])
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

    func testMenuBarMetricsAreBoundedAndUnique() {
        // Empty now means the mark-only item rather than a mistake, so it is
        // preserved. Only a missing stored key falls back to the defaults, and
        // testMenuBarMetricSelectionIsCappedAndMayBeEmpty covers that.
        XCTAssertEqual(MenuBarMetric.normalized([]), [])
        XCTAssertEqual(
            MenuBarMetric.normalized([.cpuUsage, .cpuUsage, .temperature, .gpuUsage]),
            [.cpuUsage, .temperature, .gpuUsage]
        )
        XCTAssertEqual(
            MenuBarMetric.normalized([.cpuUsage, .memoryUsed, .temperature, .gpuUsage]),
            [.cpuUsage, .memoryUsed, .temperature, .gpuUsage],
            "four fits under the cap of five"
        )
    }

    func testSustainedPressureDuration() throws {
        func levelSample(
            _ offset: TimeInterval,
            _ level: PressureLevel
        ) throws -> SystemSample {
            let encoded = try JSONEncoder().encode(SystemSample.placeholder)
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            )
            object["timestamp"] = Date(
                timeIntervalSinceReferenceDate: 1_000 + offset
            ).timeIntervalSince1970
            object["cpuPressureLevel"] = level.rawValue
            object["memoryPressureLevel"] = PressureLevel.unavailable.rawValue
            object["thermalPressureLevel"] = PressureLevel.unavailable.rawValue
            object["gpuPressureLevel"] = PressureLevel.unavailable.rawValue
            return try JSONDecoder().decode(
                SystemSample.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        }

        XCTAssertNil(SustainedPressure.duration(in: [SystemSample]()))

        let flipped = try [
            levelSample(0, .nominal),
            levelSample(10, .nominal),
            levelSample(20, .elevated),
            levelSample(30, .elevated),
            levelSample(40, .elevated)
        ]
        let flippedReading = SustainedPressure.duration(in: flipped)
        XCTAssertEqual(flippedReading?.level, .elevated)
        XCTAssertEqual(flippedReading?.duration ?? -1, 20, accuracy: 0.001)
        XCTAssertFalse(flippedReading?.boundedByHistoryWindow ?? true)

        let steady = try (0...5).map { try levelSample(Double($0) * 60, .constrained) }
        let steadyReading = SustainedPressure.duration(in: steady)
        XCTAssertEqual(steadyReading?.level, .constrained)
        XCTAssertEqual(steadyReading?.duration ?? -1, 300, accuracy: 0.001)
        XCTAssertTrue(steadyReading?.boundedByHistoryWindow ?? false)

        let unavailable = try [levelSample(0, .unavailable), levelSample(60, .unavailable)]
        XCTAssertNil(SustainedPressure.duration(in: unavailable))

        let single = try [levelSample(0, .nominal)]
        let singleReading = SustainedPressure.duration(in: single)
        XCTAssertEqual(singleReading?.duration ?? -1, 0, accuracy: 0.001)
        XCTAssertTrue(singleReading?.boundedByHistoryWindow ?? false)
    }

    func testMetricFormatting() {
        XCTAssertEqual(MetricFormat.compactBytes(16 * 1_073_741_824), "16G")
        XCTAssertEqual(
            MetricFormat.bytePair(
                8 * 1_073_741_824,
                16 * 1_073_741_824,
                unit: .gigabytes
            ),
            "8.0/16GB"
        )
        XCTAssertEqual(
            MetricFormat.bytePair(
                8 * 1_073_741_824,
                16 * 1_073_741_824,
                unit: .megabytes
            ),
            "8192/16384MB"
        )
        XCTAssertEqual(MetricFormat.temperature(25, unit: .celsius), "25°C")
        XCTAssertEqual(MetricFormat.temperature(25, unit: .fahrenheit), "77°F")
        XCTAssertEqual(MetricFormat.rate(1_500, unit: .bytes), "1500 B/s")
        XCTAssertEqual(MetricFormat.rate(1_500, unit: .kilobytes), "1.5 KB/s")
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
        XCTAssertEqual(MetricFormat.compactDuration(0), "00M")
        XCTAssertEqual(MetricFormat.compactDuration(12 * 60), "12M")
        XCTAssertEqual(MetricFormat.compactDuration((3 * 60 + 12) * 60), "03H 12M")
        XCTAssertEqual(MetricFormat.compactDuration(2 * 86_400 + 3 * 3_600), "02D 03H")
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

    func testDashboardUnitsCycleIndependently() {
        var state = DashboardUnitState()
        XCTAssertEqual(state.byteUnit(for: .memory), .gigabytes)
        XCTAssertEqual(state.temperatureUnit(for: .temperature), .celsius)
        XCTAssertEqual(state.rateUnit(for: .network), .adaptive)

        state.cycle(.memory)
        state.cycle(.temperature)
        state.cycle(.network)
        XCTAssertEqual(state.byteUnit(for: .memory), .megabytes)
        XCTAssertEqual(state.byteUnit(for: .cache), .gigabytes)
        XCTAssertEqual(state.temperatureUnit(for: .temperature), .fahrenheit)
        XCTAssertEqual(state.rateUnit(for: .network), .bytes)
        XCTAssertEqual(state.rateUnit(for: .diskIO), .adaptive)

        state.cycle(.memory)
        XCTAssertEqual(state.byteUnit(for: .memory), .gigabytes)

        state.cycle(.compressedMemory)
        state.cycle(.compression)
        XCTAssertEqual(state.byteUnit(for: .compressedMemory), .megabytes)
        XCTAssertEqual(state.rateUnit(for: .compression), .bytes)
        XCTAssertEqual(state.rateUnit(for: .swapIO), .adaptive)

        state.cycle(.gpuMemory)
        state.cycle(.diskCapacity)
        XCTAssertEqual(state.byteUnit(for: .gpuMemory), .megabytes)
        XCTAssertEqual(state.byteUnit(for: .diskCapacity), .megabytes)
        XCTAssertEqual(state.byteUnit(for: .memory), .gigabytes)
    }

    func testOlderSampleReceivesDefaultsForNewMetrics() throws {
        let encoded = try JSONEncoder().encode(SystemSample.placeholder)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "swapInPerSecond")
        object.removeValue(forKey: "swapOutPerSecond")
        object.removeValue(forKey: "isLowPowerModeEnabled")
        object.removeValue(forKey: "compressedMemoryBytes")
        object.removeValue(forKey: "compressionBytesPerSecond")
        object.removeValue(forKey: "decompressionBytesPerSecond")
        object.removeValue(forKey: "gpuMemoryUsedBytes")
        object.removeValue(forKey: "gpuMemoryRecommendedBytes")
        object.removeValue(forKey: "gpuMemoryPressure")
        object.removeValue(forKey: "diskCapacityBytes")
        object.removeValue(forKey: "diskAvailableBytes")

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(SystemSample.self, from: legacyData)

        XCTAssertEqual(decoded.swapInPerSecond, 0)
        XCTAssertEqual(decoded.swapOutPerSecond, 0)
        XCTAssertFalse(decoded.isLowPowerModeEnabled)
        XCTAssertEqual(decoded.compressedMemoryBytes, 0)
        XCTAssertEqual(decoded.compressionBytesPerSecond, 0)
        XCTAssertEqual(decoded.decompressionBytesPerSecond, 0)
        XCTAssertNil(decoded.gpuMemoryUsedBytes)
        XCTAssertNil(decoded.gpuMemoryRecommendedBytes)
        XCTAssertNil(decoded.gpuMemoryPressure)
        XCTAssertNil(decoded.diskCapacityBytes)
        XCTAssertNil(decoded.diskAvailableBytes)
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

    func testGPUMemoryParsingBounds() {
        let physicalMemory = UInt64(48 * 1_073_741_824)
        XCTAssertEqual(
            GPUCollector.parseUsedSystemMemory(
                ["In use system memory": 631_635_968],
                physicalMemory: physicalMemory
            ),
            631_635_968
        )
        XCTAssertNil(GPUCollector.parseUsedSystemMemory([:], physicalMemory: physicalMemory))
        XCTAssertNil(GPUCollector.parseUsedSystemMemory(
            ["In use system memory": 0],
            physicalMemory: physicalMemory
        ))
        // Some non-Apple drivers publish the same key in megabytes; values
        // beyond physical memory are rejected instead of trusted.
        XCTAssertNil(GPUCollector.parseUsedSystemMemory(
            ["In use system memory": 999 * 1_073_741_824],
            physicalMemory: physicalMemory
        ))
        XCTAssertEqual(
            GPUCollector.workingSetRatio(used: 9, recommended: 10) ?? .nan,
            0.9,
            accuracy: 0.0001
        )
        XCTAssertNil(GPUCollector.workingSetRatio(used: nil, recommended: 10))
        XCTAssertNil(GPUCollector.workingSetRatio(used: 9, recommended: nil))
        XCTAssertNil(GPUCollector.workingSetRatio(used: 9, recommended: 0))
        XCTAssertEqual(
            GPUCollector.workingSetRatio(used: 20, recommended: 10) ?? .nan,
            1.0,
            accuracy: 0.0001,
            "the ratio clamps at the top of the closed range"
        )
    }

    func testGpuPressureFoldsWorkingSetRatio() {
        XCTAssertEqual(GPUCollector.combinedPressure(usage: 0.2, workingSetRatio: nil), 0.2)
        XCTAssertEqual(GPUCollector.combinedPressure(usage: 0.2, workingSetRatio: 0.1), 0.2)
        XCTAssertEqual(
            GPUCollector.combinedPressure(usage: 0.2, workingSetRatio: 0.9),
            0.9,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            PressureLevel.from(utilization: GPUCollector.combinedPressure(usage: 0.2, workingSetRatio: 0.9)),
            .constrained
        )
        XCTAssertEqual(
            GPUCollector.combinedPressure(usage: 0.5, workingSetRatio: 2.0),
            1.0,
            accuracy: 0.0001,
            "a combined pressure stays within the closed range"
        )
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
        XCTAssertLessThanOrEqual(sample.compressedMemoryBytes, sample.memoryUsed)
        XCTAssertGreaterThanOrEqual(sample.compressionBytesPerSecond, 0)
        XCTAssertGreaterThanOrEqual(sample.decompressionBytesPerSecond, 0)
        if let gpuMemoryUsed = sample.gpuMemoryUsedBytes {
            XCTAssertLessThanOrEqual(gpuMemoryUsed, sample.memoryTotal)
        }
        if let gpuMemoryRecommended = sample.gpuMemoryRecommendedBytes {
            XCTAssertGreaterThan(gpuMemoryRecommended, 0)
        }
        if let gpuMemoryPressure = sample.gpuMemoryPressure {
            XCTAssertTrue((0...1).contains(gpuMemoryPressure))
        }
        if let diskCapacity = sample.diskCapacityBytes {
            XCTAssertGreaterThan(diskCapacity, 0)
        }
        if let diskAvailable = sample.diskAvailableBytes {
            XCTAssertGreaterThanOrEqual(diskAvailable, 0)
        }
        if let diskCapacity = sample.diskCapacityBytes, let diskAvailable = sample.diskAvailableBytes {
            XCTAssertLessThanOrEqual(diskAvailable, diskCapacity)
        }
        XCTAssertTrue(
            (sample.diskCapacityBytes == nil) == (sample.diskAvailableBytes == nil),
            "capacity and availability become unavailable together"
        )
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
    func testUpdateVersionComparisonIsNumericNotLexical() {
        XCTAssertTrue(UpdateChecker.isNewer("0.2.0", than: "0.1.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.0", than: "0.9.9"))
        // The case string comparison gets wrong.
        XCTAssertTrue(UpdateChecker.isNewer("0.10.0", than: "0.9.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.9.0", than: "0.10.0"))
    }

    func testUpdateVersionComparisonTreatsMissingComponentsAsZero() {
        XCTAssertFalse(UpdateChecker.isNewer("0.2", than: "0.2.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.2.0", than: "0.2"))
        XCTAssertTrue(UpdateChecker.isNewer("0.2.1", than: "0.2"))
    }

    func testUpdateOutcomeDoesNotOfferAnOlderOrEqualVersion() {
        let manifest = UpdateManifest(version: "0.1.0", url: "https://searoom.app/")
        XCTAssertEqual(
            UpdateChecker.outcome(for: manifest, current: "0.1.0"),
            .upToDate(current: "0.1.0")
        )
        XCTAssertEqual(
            UpdateChecker.outcome(for: manifest, current: "0.2.0"),
            .upToDate(current: "0.2.0")
        )
    }

    func testUpdateOutcomeRejectsAnUnusableLink() {
        let manifest = UpdateManifest(version: "9.9.9", url: "")
        guard case .failed = UpdateChecker.outcome(for: manifest, current: "0.1.0") else {
            return XCTFail("an empty URL should not produce an update prompt")
        }
    }

    // The coordinates below are the ones DashboardView carried as literals
    // before the layout became computed. If this test fails, the refactor
    // moved the dashboard rather than merely deriving it.
    func testDefaultLayoutReproducesTheOriginalFixedGeometry() {
        let layout = DashboardLayout.make(order: DashboardSection.defaults, width: 430)
        let expected: [(DashboardSection, NSRect)] = [
            (.cpu, NSRect(x: 12, y: 82, width: 198, height: 158)),
            (.memory, NSRect(x: 220, y: 82, width: 198, height: 158)),
            (.gpu, NSRect(x: 12, y: 250, width: 198, height: 158)),
            (.thermal, NSRect(x: 220, y: 250, width: 198, height: 158)),
            (.gpuMemory, NSRect(x: 12, y: 418, width: 198, height: 158)),
            (.disk, NSRect(x: 220, y: 418, width: 198, height: 158)),
            (.network, NSRect(x: 12, y: 586, width: 406, height: 122)),
            (.info, NSRect(x: 12, y: 718, width: 406, height: 88)),
            (.extras, NSRect(x: 12, y: 816, width: 406, height: 180))
        ]
        XCTAssertEqual(layout.slots.count, expected.count)
        for (index, pair) in expected.enumerated() {
            XCTAssertEqual(layout.slots[index].section, pair.0)
            XCTAssertEqual(layout.slots[index].rect, pair.1, "\(pair.0) moved")
        }
        XCTAssertEqual(layout.selfRect, NSRect(x: 12, y: 1006, width: 406, height: 42))
        XCTAssertEqual(layout.footerRect, NSRect(x: 0, y: 1062, width: 430, height: 38))
        XCTAssertEqual(layout.contentHeight, 1120)
    }

    func testFullWidthSectionAfterAnOddHalfRowLeavesNoOverlap() {
        // Network lands after a single half-width card, so CPU's row is closed
        // with its right half empty and everything below shifts by one row.
        let order: [DashboardSection] = [
            .cpu, .network, .memory, .gpu, .thermal, .gpuMemory, .disk, .info, .extras
        ]
        let layout = DashboardLayout.make(order: order, width: 430)
        let reference = DashboardLayout.make(order: DashboardSection.defaults, width: 430)
        XCTAssertEqual(layout.contentHeight, reference.contentHeight + 168)
        XCTAssertEqual(layout.rect(for: .cpu), NSRect(x: 12, y: 82, width: 198, height: 158))
        XCTAssertEqual(layout.rect(for: .network), NSRect(x: 12, y: 250, width: 406, height: 122))

        for outer in layout.slots.indices {
            for inner in layout.slots.indices where inner > outer {
                XCTAssertFalse(
                    layout.slots[outer].rect.intersects(layout.slots[inner].rect),
                    "\(layout.slots[outer].section) overlaps \(layout.slots[inner].section)"
                )
            }
            XCTAssertFalse(layout.slots[outer].rect.intersects(layout.selfRect))
            XCTAssertFalse(layout.slots[outer].rect.intersects(layout.footerRect))
        }
    }

    func testEverySectionOrderKeepsAllSectionsAndClearsTheHeader() {
        // A permutation may change the height but must never drop a section or
        // let content ride up into the header band.
        let orders: [[DashboardSection]] = [
            DashboardSection.defaults,
            DashboardSection.defaults.reversed(),
            [.extras, .cpu, .info, .memory, .network, .gpu, .thermal, .gpuMemory, .disk]
        ]
        for order in orders {
            let layout = DashboardLayout.make(order: order, width: 430)
            XCTAssertEqual(Set(layout.slots.map(\.section)), Set(DashboardSection.allCases))
            XCTAssertEqual(layout.slots.map(\.section), order)
            for slot in layout.slots {
                XCTAssertGreaterThanOrEqual(slot.rect.minY, DashboardLayout.contentTop)
            }
            XCTAssertGreaterThan(layout.selfRect.minY, layout.slots.map(\.rect.maxY).max() ?? 0)
            XCTAssertEqual(layout.footerRect.minY, layout.selfRect.maxY + 14)
        }
    }

    func testDropTargetFollowsThePointerAcrossRowsAndColumns() {
        let layout = DashboardLayout.make(order: DashboardSection.defaults, width: 430)

        // Dragging CPU onto the right half of the last card row puts it after
        // every card it has passed, and dropping back on itself is a no-op.
        let ontoDiskTrailing = NSPoint(x: 400, y: 497)
        let trailingIndex = layout.insertionIndex(for: ontoDiskTrailing, excluding: .cpu)
        XCTAssertEqual(
            DashboardSection.reordered(DashboardSection.defaults, moving: .cpu, to: trailingIndex),
            [.memory, .gpu, .thermal, .gpuMemory, .disk, .cpu, .network, .info, .extras]
        )

        let ontoOwnPosition = NSPoint(x: 60, y: 120)
        XCTAssertEqual(
            DashboardSection.reordered(
                DashboardSection.defaults,
                moving: .cpu,
                to: layout.insertionIndex(for: ontoOwnPosition, excluding: .cpu)
            ),
            DashboardSection.defaults
        )

        // Above everything means first; below everything means last.
        XCTAssertEqual(layout.insertionIndex(for: NSPoint(x: 20, y: 0), excluding: .cpu), 0)
        XCTAssertEqual(
            layout.insertionIndex(for: NSPoint(x: 400, y: 2000), excluding: .cpu),
            DashboardSection.allCases.count - 1,
            "the dragged section is excluded, so the last index is one short of the count"
        )
    }

    func testDashboardSectionOrderRoundTripsAndMigrates() throws {
        var settings = AppSettings()
        XCTAssertEqual(settings.dashboardSectionOrder, DashboardSection.defaults)
        settings.dashboardSectionOrder = [
            .gpuMemory, .cpu, .memory, .gpu, .thermal, .disk, .network, .info, .extras
        ]
        let encoded = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: encoded), settings)

        // An archive written before the setting existed keeps the shipped order.
        let legacy = Data("{\"sampleInterval\":5}".utf8)
        let migrated = try JSONDecoder().decode(AppSettings.self, from: legacy)
        XCTAssertEqual(migrated.dashboardSectionOrder, DashboardSection.defaults)

        // A section retired in some future build is dropped, and the partial
        // order is completed rather than rejected.
        let forward = Data("{\"dashboardSectionOrder\":[\"disk\",\"futureCard\"]}".utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: forward)
        XCTAssertEqual(decoded.dashboardSectionOrder.first, .disk)
        XCTAssertEqual(Set(decoded.dashboardSectionOrder), Set(DashboardSection.allCases))
    }

    func testReorderingMovesOneSectionAndKeepsTheRest() {
        let order = DashboardSection.defaults
        XCTAssertEqual(
            DashboardSection.reordered(order, moving: .disk, to: 0).first,
            .disk
        )
        XCTAssertEqual(
            DashboardSection.reordered(order, moving: .cpu, to: order.count - 1).last,
            .cpu
        )
        XCTAssertEqual(
            DashboardSection.reordered(order, moving: .cpu, to: 0),
            order,
            "a move to the position it already holds is a no-op"
        )
        // Out-of-range indices clamp instead of trapping, because the index
        // comes from a pointer position during a drag.
        XCTAssertEqual(DashboardSection.reordered(order, moving: .gpu, to: -5).first, .gpu)
        XCTAssertEqual(DashboardSection.reordered(order, moving: .gpu, to: 99).last, .gpu)
        for target in [0, 3, 8] {
            let moved = DashboardSection.reordered(order, moving: .network, to: target)
            XCTAssertEqual(Set(moved), Set(DashboardSection.allCases))
            XCTAssertEqual(moved.count, DashboardSection.allCases.count)
        }
    }

    func testDashboardSectionNormalizationRepairsUserData() {
        XCTAssertEqual(DashboardSection.normalized([]), DashboardSection.defaults)
        XCTAssertEqual(
            DashboardSection.normalized([.disk, .disk, .cpu]).prefix(2).map { $0 },
            [.disk, .cpu],
            "duplicates collapse and the surviving order is respected"
        )
        XCTAssertEqual(
            Set(DashboardSection.normalized([.extras])),
            Set(DashboardSection.allCases),
            "a partial array is completed rather than rejected"
        )
        XCTAssertEqual(DashboardSection.normalized([.extras]).first, .extras)
        XCTAssertEqual(
            DashboardSection.normalized(DashboardSection.defaults),
            DashboardSection.defaults
        )
    }

}
