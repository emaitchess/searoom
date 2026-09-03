import Foundation

enum SelfTest {
    static func run() -> Bool {
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }

        check(PressureLevel.from(utilization: 0.70) == .elevated, "pressure thresholds")
        check(PressureLevel.constrained.compactLabel == "TIGHT", "compact pressure label")
        check(MetricFormat.percent(0.427) == "43%", "percent formatting")
        check(MetricFormat.unboundedPercent(1.25) == "125%", "process percent formatting")
        check(
            MetricFormat.bytePair(
                8 * 1_073_741_824,
                16 * 1_073_741_824,
                unit: .megabytes
            ) == "8192/16384MB",
            "selectable byte unit formatting"
        )
        check(
            MetricFormat.temperature(25, unit: .fahrenheit) == "77°F",
            "selectable temperature unit formatting"
        )
        check(
            MetricFormat.rate(1_500, unit: .kilobytes) == "1.5 KB/s",
            "selectable rate unit formatting"
        )
        check(MetricFormat.fixedField("8%", columns: 4) == "  8%", "fixed metric field")
        check(MetricFormat.fixedLabel("BAT", columns: 4) == "BAT ", "fixed metric label")
        check(MetricFormat.uptime(90_061) == "01D 01H", "uptime formatting")
        check(MetricFormat.compactDuration(12 * 60) == "12M", "compact duration minutes")
        check(MetricFormat.compactDuration((3 * 60 + 12) * 60) == "03H 12M", "compact duration hours")
        check(MetricFormat.compactDuration(2 * 86_400 + 3 * 3_600) == "02D 03H", "compact duration days")
        check(
            MetricFormat.fanActivity([
                FanSample(name: "FAN 1", rpm: 2_314),
                FanSample(name: "FAN 2", rpm: 2_500)
            ]) == "F1 2314 · F2 2500",
            "compact fan formatting"
        )
        check(ThermalCollector.sensorDecoderSelfTest(), "SMC sensor decoding")

        check(UpdateChecker.isNewer("0.2.0", than: "0.1.0"), "update check sees a newer version")
        check(!UpdateChecker.isNewer("0.1.0", than: "0.1.0"), "update check treats equal versions as current")
        check(!UpdateChecker.isNewer("0.1.0", than: "0.2.0"), "update check does not offer a downgrade")
        // Lexical comparison would call 0.9.0 newer than 0.10.0.
        check(UpdateChecker.isNewer("0.10.0", than: "0.9.0"), "update check compares numerically")
        check(!UpdateChecker.isNewer("0.2", than: "0.2.0"), "update check pads missing components")
        check(
            UpdateChecker.outcome(
                for: UpdateManifest(version: "0.1.0", url: "https://example.invalid"),
                current: "0.1.0"
            ) == .upToDate(current: "0.1.0"),
            "update outcome reports up to date"
        )
        check(
            abs((BatteryCollector.normalizeTemperature(2_759) ?? 0) - 27.59) < 0.001,
            "battery temperature scaling"
        )
        check(
            GPUCollector.parseUsedSystemMemory(
                ["In use system memory": 631_635_968],
                physicalMemory: 48 * 1_073_741_824
            ) == 631_635_968,
            "GPU working-set memory parsing"
        )
        check(
            GPUCollector.parseUsedSystemMemory(
                ["In use system memory": 0],
                physicalMemory: 48 * 1_073_741_824
            ) == nil,
            "GPU working-set memory rejects zero"
        )
        check(
            GPUCollector.parseUsedSystemMemory(
                ["In use system memory": 999_999_999_999_999],
                physicalMemory: 48 * 1_073_741_824
            ) == nil,
            "GPU working-set memory rejects out-of-bounds values"
        )
        check(
            abs((GPUCollector.workingSetRatio(used: 9, recommended: 10) ?? 0) - 0.9) < 0.0001,
            "GPU working-set ratio"
        )
        check(
            abs(GPUCollector.combinedPressure(usage: 0.2, workingSetRatio: 0.9) - 0.9) < 0.0001,
            "GPU pressure folds the working-set ratio"
        )
        let legacySettings = Data("{\"sampleInterval\":5}".utf8)
        let decodedSettings = try? JSONDecoder().decode(AppSettings.self, from: legacySettings)
        check(decodedSettings?.historyMinutes == 30, "settings migration")
        check(decodedSettings?.menuBarMetrics == MenuBarMetric.defaults, "menu bar metric migration")
        let presetSettings = Data("{\"menuBarPreset\":\"compute\"}".utf8)
        let decodedPreset = try? JSONDecoder().decode(AppSettings.self, from: presetSettings)
        check(decodedPreset?.menuBarMetrics == [.cpuUsage, .gpuUsage], "preset migration")
        let minimalSettings = Data("{\"menuBarPreset\":\"minimal\"}".utf8)
        let decodedMinimal = try? JSONDecoder().decode(AppSettings.self, from: minimalSettings)
        check(decodedMinimal?.menuBarMetrics.isEmpty == true, "minimal preset migration")
        check(decodedSettings?.hasCompletedLaunchAtLoginPrompt == true, "launch prompt migration")
        check(AppSettings().hasCompletedLaunchAtLoginPrompt == false, "fresh launch prompt default")
        let invalidSettings = Data("{\"sampleInterval\":0,\"historyMinutes\":999999}".utf8)
        let decodedInvalidSettings = try? JSONDecoder().decode(AppSettings.self, from: invalidSettings)
        check(decodedInvalidSettings?.sampleInterval == 2, "sample interval bounds")
        check(decodedInvalidSettings?.historyMinutes == 30, "history duration bounds")
        let futureMetricSettings = Data(
            "{\"customMenuBarMetrics\":[\"cpuUsage\",\"futureMetric\"]}".utf8
        )
        let decodedFutureMetrics = try? JSONDecoder().decode(
            AppSettings.self,
            from: futureMetricSettings
        )
        check(decodedFutureMetrics?.menuBarMetrics == [.cpuUsage], "future metric migration")
        check(MenuBarMetric.memoryFreeUsed.title == "RAM Free / Used", "combined RAM metric")
        check(MenuBarMetric.gpuMemory.title == "GPU Memory", "GPU memory metric title")
        check(MenuBarMetric.diskFree.title == "Disk Free", "disk free metric title")
        check(
            MenuBarMetric.networkUpDown.title == "Network Upload/Download",
            "paired network metric title"
        )
        check(
            MenuBarMetric.normalized([.cpuUsage, .cpuUsage, .temperature, .gpuUsage])
                == [.cpuUsage, .temperature, .gpuUsage],
            "custom metric normalization"
        )
        var ring = RingBuffer<Int>()
        for value in 0..<10 { ring.append(value, maximumCount: 4) }
        check(ring.snapshot() == [6, 7, 8, 9], "ring buffer wrap order")
        ring.removeFirst(while: { $0 < 8 }, keepingAtLeast: 1)
        check(ring.snapshot() == [8, 9], "ring buffer pruning")
        var trendPolicy = DashboardTrendRefreshPolicy()
        let trendStart = ContinuousClock().now
        check(trendPolicy.shouldRefresh(at: trendStart), "initial trend refresh")
        check(
            !trendPolicy.shouldRefresh(at: trendStart.advanced(by: .milliseconds(4_999))),
            "trend refresh throttle"
        )
        check(
            trendPolicy.shouldRefresh(at: trendStart.advanced(by: .seconds(5))),
            "trend refresh deadline"
        )
        let trendDates = [0.0, 2, 7].map(Date(timeIntervalSinceReferenceDate: 1_000).addingTimeInterval)
        let nearestTrendIndex = DashboardTrendSampleLocator.nearestIndex(
            to: Date(timeIntervalSinceReferenceDate: 1_003),
            count: trendDates.count,
            timestampAt: { trendDates[$0] }
        )
        check(nearestTrendIndex == 1, "trend hover sample alignment")
        let primaryTrendMetrics: [DashboardTrendMetric] = [
            .cpu, .memory, .gpu, .thermal, .gpuMemory, .diskUsed
        ]
        check(
            primaryTrendMetrics.allSatisfy { $0.synchronizedMetrics == primaryTrendMetrics },
            "primary trend hover synchronization"
        )
        check(
            DashboardTrendMetric.network.synchronizedMetrics == [.network],
            "network trend hover isolation"
        )
        var dashboardUnits = DashboardUnitState()
        dashboardUnits.cycle(.memory)
        dashboardUnits.cycle(.temperature)
        dashboardUnits.cycle(.network)
        check(dashboardUnits.byteUnit(for: .memory) == .megabytes, "memory unit rotation")
        check(
            dashboardUnits.temperatureUnit(for: .temperature) == .fahrenheit,
            "temperature unit rotation"
        )
        check(dashboardUnits.rateUnit(for: .network) == .bytes, "rate unit rotation")
        check(dashboardUnits.rateUnit(for: .diskIO) == .adaptive, "independent unit rotation")
        if let encodedSample = try? JSONEncoder().encode(SystemSample.placeholder),
           var legacySample = try? JSONSerialization.jsonObject(with: encodedSample) as? [String: Any] {
            legacySample.removeValue(forKey: "swapInPerSecond")
            legacySample.removeValue(forKey: "swapOutPerSecond")
            legacySample.removeValue(forKey: "isLowPowerModeEnabled")
            legacySample.removeValue(forKey: "compressedMemoryBytes")
            legacySample.removeValue(forKey: "compressionBytesPerSecond")
            legacySample.removeValue(forKey: "decompressionBytesPerSecond")
            legacySample.removeValue(forKey: "gpuMemoryUsedBytes")
            legacySample.removeValue(forKey: "gpuMemoryRecommendedBytes")
            legacySample.removeValue(forKey: "gpuMemoryPressure")
            legacySample.removeValue(forKey: "diskCapacityBytes")
            legacySample.removeValue(forKey: "diskAvailableBytes")
            let legacySampleData = try? JSONSerialization.data(withJSONObject: legacySample)
            let decodedSample = legacySampleData.flatMap {
                try? JSONDecoder().decode(SystemSample.self, from: $0)
            }
            check(decodedSample?.swapInPerSecond == 0, "sample swap input migration")
            check(decodedSample?.swapOutPerSecond == 0, "sample swap output migration")
            check(decodedSample?.isLowPowerModeEnabled == false, "sample power migration")
            check(decodedSample?.compressedMemoryBytes == 0, "sample compressed memory migration")
            check(decodedSample?.compressionBytesPerSecond == 0, "sample compression rate migration")
            check(decodedSample?.decompressionBytesPerSecond == 0, "sample decompression rate migration")
            check(decodedSample?.gpuMemoryUsedBytes == nil, "sample GPU working-set migration")
            check(decodedSample?.gpuMemoryPressure == nil, "sample GPU memory pressure migration")
            check(decodedSample?.diskCapacityBytes == nil, "sample disk capacity migration")
            check(decodedSample?.diskAvailableBytes == nil, "sample disk availability migration")
        } else {
            failures.append("sample migration fixture")
        }

        func sustainedSample(_ offset: TimeInterval, level raw: Int) -> SystemSample? {
            guard let encoded = try? JSONEncoder().encode(SystemSample.placeholder),
                  var object = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            else { return nil }
            object["timestamp"] = Date(
                timeIntervalSinceReferenceDate: 1_000 + offset
            ).timeIntervalSince1970
            object["cpuPressureLevel"] = raw
            object["memoryPressureLevel"] = -1
            object["thermalPressureLevel"] = -1
            object["gpuPressureLevel"] = -1
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
            return try? JSONDecoder().decode(SystemSample.self, from: data)
        }
        let sustainedFlip = [0.0, 10, 20, 30, 40]
            .compactMap { sustainedSample($0, level: $0 < 20 ? 0 : 1) }
        if let reading = SustainedPressure.duration(in: sustainedFlip) {
            check(reading.level == .elevated, "sustained pressure level")
            check(abs(reading.duration - 20) < 0.001, "sustained pressure duration")
            check(!reading.boundedByHistoryWindow, "sustained pressure boundary")
        } else {
            failures.append("sustained pressure fixture")
        }
        let sustainedSteady = [0.0, 60, 120, 180]
            .compactMap { sustainedSample($0, level: 2) }
        if let reading = SustainedPressure.duration(in: sustainedSteady) {
            check(reading.boundedByHistoryWindow, "sustained pressure window saturation")
            check(abs(reading.duration - 180) < 0.001, "sustained pressure window duration")
        } else {
            failures.append("sustained pressure steady fixture")
        }
        check(
            SustainedPressure.duration(in: [SystemSample]()) == nil,
            "sustained pressure empty history"
        )

        let collector = SystemMetricsCollector()
        _ = collector.collect()
        let sample = collector.collect()
        check(sample.memoryTotal > 0, "physical memory")
        check(sample.memoryUsed <= sample.memoryTotal, "bounded memory")
        check(sample.swapInPerSecond >= 0, "nonnegative swap input")
        check(sample.swapOutPerSecond >= 0, "nonnegative swap output")
        check(sample.compressedMemoryBytes <= sample.memoryUsed, "bounded compressed memory")
        check(sample.compressionBytesPerSecond >= 0, "nonnegative compression rate")
        check(sample.decompressionBytesPerSecond >= 0, "nonnegative decompression rate")
        if let gpuMemoryUsed = sample.gpuMemoryUsedBytes {
            check(gpuMemoryUsed <= sample.memoryTotal, "bounded GPU working set")
        }
        if let gpuMemoryPressure = sample.gpuMemoryPressure {
            check((0...1).contains(gpuMemoryPressure), "bounded GPU memory pressure")
        }
        if let diskCapacity = sample.diskCapacityBytes {
            check(diskCapacity > 0, "bounded disk capacity")
            if let diskAvailable = sample.diskAvailableBytes {
                check(diskAvailable <= diskCapacity, "bounded disk availability")
            }
        }
        check(
            (sample.diskCapacityBytes == nil) == (sample.diskAvailableBytes == nil),
            "disk capacity and availability agree"
        )
        check((0...1).contains(sample.cpuUsage), "bounded CPU")
        check(sample.processMemoryBytes > 0, "self memory")

        if failures.isEmpty {
            return true
        }
        for failure in failures { fputs("Searoom self-test failed: \(failure)\n", stderr) }
        return false
    }

    static func dumpSample() -> Bool {
        let collector = SystemMetricsCollector()
        _ = collector.collect()
        Thread.sleep(forTimeInterval: 0.25)
        let sample = collector.collect()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(sample) else { return false }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        return true
    }
}
