import Foundation

final class SystemMetricsCollector {
    private let cpu = CPUCollector()
    private let memory = MemoryCollector()
    private let network = NetworkCollector()
    private let disk = DiskCollector()
    private let thermal = ThermalCollector()
    private let gpu = GPUCollector()
    private let battery = BatteryCollector()
    private let process = ProcessCollector()
    private let clock = ContinuousClock()
    private var nextDiskReading: ContinuousClock.Instant?
    private var nextThermalReading: ContinuousClock.Instant?
    private var nextGPUReading: ContinuousClock.Instant?
    private var cachedDisk: (read: Double, write: Double) = (0, 0)
    private var cachedThermal: (temperature: Double?, pressureLevel: PressureLevel, fans: [FanSample]) =
        (nil, .unavailable, [])
    private var cachedGPU: (
        usage: Double?,
        pressure: Double?,
        level: PressureLevel,
        memoryUsedBytes: UInt64?,
        memoryRecommendedBytes: UInt64?,
        memoryPressure: Double?
    ) = (nil, nil, .unavailable, nil, nil, nil)

    func collect() -> SystemSample {
        let now = Date.now
        let monotonicNow = clock.now
        let cpuReading = cpu.read()
        let memoryReading = memory.read()
        let networkReading = network.read()
        if nextDiskReading.map({ monotonicNow >= $0 }) ?? true {
            cachedDisk = disk.read()
            nextDiskReading = monotonicNow.advanced(by: .seconds(5))
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
            uptime: ProcessInfo.processInfo.systemUptime,
            processCPUUsage: processReading.cpu,
            processMemoryBytes: processReading.memory,
            processCount: processReading.processCount,
            batteryPercent: batteryReading.percent,
            isOnExternalPower: batteryReading.externalPower,
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
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
