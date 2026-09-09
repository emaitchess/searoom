import Foundation

final class SystemMetricsCollector {
    private let cpu = CPUCollector()
    private let memory = MemoryCollector()
    private let network = NetworkCollector()
    private let disk = DiskCollector()
    private let diskCapacity = DiskCapacityCollector()
    private let thermal = ThermalCollector()
    private let gpu = GPUCollector()
    private let battery = BatteryCollector()
    private let process = ProcessCollector()
    private let clock = ContinuousClock()
    private var nextDiskReading: ContinuousClock.Instant?
    private var nextDiskCapacityReading: ContinuousClock.Instant?
    private var nextThermalReading: ContinuousClock.Instant?
    private var nextGPUReading: ContinuousClock.Instant?
    private var cachedDisk: DiskReading = DiskReading(read: 0, write: 0, availability: .warmingUp)
    private var cachedDiskCapacity = DiskCapacityReading(
        capacityBytes: nil,
        availableBytes: nil,
        availability: .unavailable
    )
    private var cachedThermal = ThermalReading(
        temperature: nil,
        pressureLevel: .unavailable,
        fans: [],
        temperatureAvailability: .unavailable,
        fansAvailability: .unavailable
    )
    private var cachedGPU = GPUReading(
        usage: nil,
        pressure: nil,
        level: .unavailable,
        memoryUsedBytes: nil,
        memoryRecommendedBytes: nil,
        memoryPressure: nil,
        availability: .unavailable
    )

    /// Collects one sample. `forceDiskCounterRefresh` bypasses only the outer
    /// five-second disk-counter cache so a CLI warm-up can complete its disk
    /// baseline. It must never force GPU, thermal, battery, capacity, or
    /// process-count refreshes.
    func collect(forceDiskCounterRefresh: Bool = false) -> SystemSample {
        let now = Date.now
        let monotonicNow = clock.now
        let cpuReading = cpu.read()
        let memoryReading = memory.read()
        let networkReading = network.read()
        if forceDiskCounterRefresh || nextDiskReading.map({ monotonicNow >= $0 }) ?? true {
            cachedDisk = disk.read()
            nextDiskReading = monotonicNow.advanced(by: .seconds(5))
        }
        if nextDiskCapacityReading.map({ monotonicNow >= $0 }) ?? true {
            cachedDiskCapacity = diskCapacity.read()
            nextDiskCapacityReading = monotonicNow.advanced(by: .seconds(30))
        }
        if nextThermalReading.map({ monotonicNow >= $0 }) ?? true {
            cachedThermal = thermal.read()
            nextThermalReading = monotonicNow.advanced(by: .seconds(6))
        }
        if nextGPUReading.map({ monotonicNow >= $0 }) ?? true {
            cachedGPU = gpu.read()
            nextGPUReading = monotonicNow.advanced(by: .seconds(7))
        }
        let diskReading = cachedDisk
        let thermalReading = cachedThermal
        let gpuReading = cachedGPU
        let diskCapacityReading = cachedDiskCapacity
        let batteryReading = battery.read()
        let processReading = process.read()
        let temperature = thermalReading.temperature ?? batteryReading.temperature
        let temperatureSource: TemperatureSource = if thermalReading.temperature != nil {
            .cpuPackage
        } else if batteryReading.temperature != nil {
            .battery
        } else {
            .unavailable
        }
        let temperatureAvailability: ReadingAvailability =
            thermalReading.temperatureAvailability == .available
                || batteryReading.temperature != nil
                ? .available : .unavailable

        return SystemSample(
            timestamp: now,
            cpuUsage: cpuReading.usage,
            cpuPressure: cpuReading.pressure,
            cpuPressureLevel: cpuReading.pressureLevel,
            loadAverage1m: cpuReading.loadAverage1m,
            logicalCPUCount: cpuReading.logicalCPUCount,
            memoryTotal: memoryReading.total,
            memoryUsed: memoryReading.used,
            memoryAvailable: memoryReading.available,
            memoryCached: memoryReading.cached,
            swapUsed: memoryReading.swapUsed,
            swapInPerSecond: memoryReading.swapInPerSecond,
            swapOutPerSecond: memoryReading.swapOutPerSecond,
            compressedMemoryBytes: memoryReading.compressedBytes,
            compressionBytesPerSecond: memoryReading.compressionBytesPerSecond,
            decompressionBytesPerSecond: memoryReading.decompressionBytesPerSecond,
            memoryPressure: memoryReading.pressure,
            memoryPressureLevel: memoryReading.pressureLevel,
            memorySystemPressureLevel: memoryReading.systemPressureLevel,
            temperatureCelsius: temperature,
            temperatureSource: temperatureSource,
            thermalPressureLevel: thermalReading.pressureLevel,
            gpuUsage: gpuReading.usage,
            gpuPressure: gpuReading.pressure,
            gpuPressureLevel: gpuReading.level,
            gpuMemoryUsedBytes: gpuReading.memoryUsedBytes,
            gpuMemoryRecommendedBytes: gpuReading.memoryRecommendedBytes,
            gpuMemoryPressure: gpuReading.memoryPressure,
            fans: thermalReading.fans,
            networkDownloadPerSecond: networkReading.download,
            networkUploadPerSecond: networkReading.upload,
            diskReadPerSecond: diskReading.read,
            diskWritePerSecond: diskReading.write,
            diskCapacityBytes: diskCapacityReading.capacityBytes,
            diskAvailableBytes: diskCapacityReading.availableBytes,
            uptime: ProcessInfo.processInfo.systemUptime,
            processCPUUsage: processReading.cpu,
            processMemoryBytes: processReading.memory,
            processCount: processReading.processCount,
            batteryPercent: batteryReading.percent,
            isOnExternalPower: batteryReading.externalPower,
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            availability: SampleAvailability(
                cpuUsageLoad: cpuReading.availability,
                vmStatistics: memoryReading.vmStatisticsAvailability,
                swapUsage: memoryReading.swapUsageAvailability,
                swapIO: memoryReading.swapIOAvailability,
                compressionIO: memoryReading.compressionIOAvailability,
                networkIO: networkReading.availability,
                diskIO: diskReading.availability,
                diskCapacity: diskCapacityReading.availability,
                temperature: temperatureAvailability,
                fans: thermalReading.fansAvailability,
                gpu: gpuReading.availability,
                battery: batteryReading.availability,
                processCPU: processReading.cpuAvailability,
                processMemory: processReading.memoryAvailability,
                processCount: processReading.processCountAvailability
            )
        )
    }
}

final class MetricsEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.searoom.metrics", qos: .utility)
    private let collector = SystemMetricsCollector()
    private var timer: DispatchSourceTimer?

    func start(
        interval: TimeInterval,
        onSample: @escaping @MainActor @Sendable (SystemSample) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            timer?.cancel()

            let timer = DispatchSource.makeTimerSource(queue: queue)
            let repeatingInterval = max(1, interval)
            let leewayMilliseconds = Int(min(1, repeatingInterval * 0.15) * 1_000)
            timer.schedule(
                deadline: .now(),
                repeating: repeatingInterval,
                leeway: .milliseconds(leewayMilliseconds)
            )
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let sample = autoreleasepool { collector.collect() }
                DispatchQueue.main.async { onSample(sample) }
            }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }
}
