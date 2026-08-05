import AppKit

@MainActor
final class DashboardView: NSView {
    var onOpenSettings: (() -> Void)?
    var onOpenActivityMonitor: (() -> Void)?
    var onQuit: (() -> Void)?

    private let model: AppModel
    private var settingsRect = NSRect.zero
    private var activityMonitorRect = NSRect.zero
    private var quitRect = NSRect.zero
    private var graphRegions: [GraphRegion] = []
    private var graphCache: GraphCache?
    private var hoverState: HoverState?
    private var hoverTrackingArea: NSTrackingArea?
    private let hoverOverlay = GraphHoverOverlayView()
    private let refreshClock = ContinuousClock()
    private var trendRefreshPolicy = DashboardTrendRefreshPolicy()
    private var livePresentation: LivePresentation?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(model: AppModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: 430, height: 925))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Searoom system dashboard")
        addSubview(hoverOverlay)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh(forceTrend: Bool = false) {
        let nextPresentation = makeLivePresentation()
        let previousPresentation = livePresentation
        livePresentation = nextPresentation

        let now = refreshClock.now
        let trendIsDue = trendRefreshPolicy.shouldRefresh(at: now, force: forceTrend)
        if trendIsDue {
            graphCache = nil
            invalidateTrendRegions()
        }

        if forceTrend || previousPresentation == nil {
            needsDisplay = true
        } else if let previousPresentation {
            invalidateChangedLiveRegions(from: previousPresentation, to: nextPresentation)
        }
        updateAccessibilitySummary()
    }

    func prepareForClose() {
        hoverState = nil
        hoverOverlay.hide()
        graphCache = nil
        livePresentation = nil
        trendRefreshPolicy.reset()
        NSCursor.arrow.set()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let theme = SearoomTheme(appearance: effectiveAppearance)
        theme.paper.setFill()
        dirtyRect.fill()

        let sample = model.currentSample
        let margin: CGFloat = 12
        let gap: CGFloat = 10
        let cardWidth = (bounds.width - margin * 2 - gap) / 2
        let headerRect = NSRect(x: 0, y: 0, width: bounds.width, height: 68)
        let cpuRect = NSRect(x: margin, y: 82, width: cardWidth, height: 158)
        let memoryRect = NSRect(x: margin + cardWidth + gap, y: 82, width: cardWidth, height: 158)
        let gpuRect = NSRect(x: margin, y: 250, width: cardWidth, height: 158)
        let thermalRect = NSRect(x: margin + cardWidth + gap, y: 250, width: cardWidth, height: 158)
        let networkRect = NSRect(x: margin, y: 418, width: bounds.width - margin * 2, height: 122)
        let infoRect = NSRect(x: margin, y: 550, width: bounds.width - margin * 2, height: 88)
        let extrasRect = NSRect(x: margin, y: 648, width: bounds.width - margin * 2, height: 153)
        let selfRect = NSRect(x: margin, y: 811, width: bounds.width - margin * 2, height: 42)
        let footerRect = NSRect(x: 0, y: 867, width: bounds.width, height: 38)
        graphRegions = [
            GraphRegion(metric: .cpu, rect: graphRect(for: cpuRect)),
            GraphRegion(metric: .memory, rect: graphRect(for: memoryRect)),
            GraphRegion(metric: .gpu, rect: graphRect(for: gpuRect)),
            GraphRegion(metric: .thermal, rect: graphRect(for: thermalRect)),
            GraphRegion(metric: .network, rect: networkGraphRect(for: networkRect))
        ]
        let needsGraphs = graphRegions.contains { needsToDraw($0.rect) }
        let graphs = needsGraphs
            ? cachedGraphs(
                cardLimit: Int(graphRect(for: cpuRect).width),
                networkLimit: Int(networkGraphRect(for: networkRect).width)
            )
            : nil

        if needsToDraw(headerRect) { drawHeader(sample: sample, theme: theme) }
        if needsToDraw(cpuRect) { drawMetricCard(
            rect: cpuRect,
            title: "CPU",
            value: MetricFormat.percent(sample.cpuUsage),
            detail: String(format: "LOAD %.2f · %d CORES", sample.loadAverage1m, sample.logicalCPUCount),
            pressure: sample.cpuPressureLevel,
            values: graphs?.cpu ?? [],
            drawsGraph: needsToDraw(graphRect(for: cpuRect)),
            theme: theme
        ) }
        if needsToDraw(memoryRect) { drawMetricCard(
            rect: memoryRect,
            title: "MEMORY",
            value: "\(MetricFormat.compactBytes(sample.memoryUsed))/\(MetricFormat.compactBytes(sample.memoryTotal))",
            detail: "FREE \(MetricFormat.compactBytes(sample.memoryAvailable)) · SWAP \(MetricFormat.compactBytes(sample.swapUsed))",
            pressure: sample.memoryPressureLevel,
            values: graphs?.memory ?? [],
            drawsGraph: needsToDraw(graphRect(for: memoryRect)),
            theme: theme
        ) }

        if needsToDraw(gpuRect) { drawMetricCard(
            rect: gpuRect,
            title: "GPU",
            value: sample.gpuUsage.map(MetricFormat.percent) ?? "N/A",
            detail: sample.gpuUsage == nil ? "SENSOR UNAVAILABLE" : "GRAPHICS LOAD",
            pressure: sample.gpuPressureLevel,
            values: graphs?.gpu ?? [],
            drawsGraph: needsToDraw(graphRect(for: gpuRect)),
            theme: theme
        ) }
        if needsToDraw(thermalRect) { drawMetricCard(
            rect: thermalRect,
            title: "THERMAL",
            value: MetricFormat.temperature(sample.temperatureCelsius),
            detail: sample.fans.isEmpty
                ? "\(sample.temperatureSource.label) · FAN N/A"
                : "\(sample.temperatureSource.label) · "
                    + sample.fans.map { "\(Int($0.rpm)) RPM" }.joined(separator: " · "),
            pressure: sample.thermalPressureLevel,
            values: graphs?.thermal ?? [],
            drawsGraph: needsToDraw(graphRect(for: thermalRect)),
            theme: theme
        ) }

        if needsToDraw(networkRect) { drawNetworkCard(
            rect: networkRect,
            sample: sample,
            downloads: graphs?.download ?? [],
            uploads: graphs?.upload ?? [],
            drawsGraph: needsToDraw(networkGraphRect(for: networkRect)),
            theme: theme
        ) }

        if needsToDraw(infoRect) { drawInfoPair(
            rect: infoRect,
            leftTitle: "FAN ACTIVITY",
            leftValue: MetricFormat.fanActivity(sample.fans),
            rightTitle: "UPTIME",
            rightValue: MetricFormat.uptime(sample.uptime),
            theme: theme
        ) }

        if needsToDraw(extrasRect) { drawExtrasCard(
            rect: extrasRect,
            sample: sample,
            theme: theme
        ) }
        if needsToDraw(selfRect) { drawSelfCard(
            rect: selfRect,
            sample: sample,
            theme: theme
        ) }
        if needsToDraw(footerRect) { drawFooter(y: 867, theme: theme) }
        if needsGraphs { updateHoverOverlay() }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if settingsRect.contains(point) { onOpenSettings?() }
        else if activityMonitorRect.contains(point) { onOpenActivityMonitor?() }
        else if quitRect.contains(point) { onQuit?() }
        else { super.mouseDown(with: event) }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let region = graphRegions.first(where: { $0.rect.contains(point) }),
              !model.history.isEmpty else {
            clearHover()
            return
        }

        let fraction = min(1, max(0, (point.x - region.rect.minX) / max(1, region.rect.width)))
        let index = hoverSampleIndex(at: fraction)
        let nextState = HoverState(
            metric: region.metric,
            sampleTimestamp: model.history[index].timestamp
        )
        NSCursor.crosshair.set()
        guard nextState != hoverState else { return }
        hoverState = nextState
        updateHoverOverlay()
    }

    override func mouseExited(with event: NSEvent) {
        clearHover()
    }

    override func scrollWheel(with event: NSEvent) {
        clearHover()
        super.scrollWheel(with: event)
    }

    private func drawHeader(sample: SystemSample, theme: SearoomTheme) {
        let pressureColor = theme.color(for: sample.overallPressureLevel)
        let band = NSBezierPath(rect: NSRect(x: 0, y: 0, width: bounds.width, height: 68))
        DitherPattern.fill(band, color: theme.ink.withAlphaComponent(0.16), density: 0.25)

        drawText("SEAROOM", at: NSPoint(x: 14, y: 16), font: SearoomFont.metric(22), color: theme.ink)
        drawText(
            "SYSTEM TELEMETRY",
            at: NSPoint(x: 15, y: 44),
            font: SearoomFont.metric(9),
            color: theme.subdued
        )

        let status = sample.overallPressureLevel.systemLabel
        let statusSize = textSize(status, font: SearoomFont.metric(11))
        let statusRect = NSRect(
            x: bounds.width - statusSize.width - 27,
            y: 20,
            width: statusSize.width + 15,
            height: 25
        )
        pressureColor.setStroke()
        let outline = NSBezierPath(rect: statusRect.integral)
        outline.lineWidth = 1
        outline.stroke()
        let marker = NSBezierPath(rect: NSRect(x: statusRect.minX + 5, y: statusRect.minY + 8, width: 5, height: 9))
        DitherPattern.fill(marker, color: pressureColor, density: density(for: sample.overallPressureLevel))
        drawText(
            status,
            at: NSPoint(x: statusRect.minX + 14, y: statusRect.minY + 6),
            font: SearoomFont.metric(10),
            color: pressureColor
        )
        theme.ink.withAlphaComponent(0.65).setFill()
        NSRect(x: 0, y: 67, width: bounds.width, height: 1).fill()
    }

    private func drawMetricCard(
        rect: NSRect,
        title: String,
        value: String,
        detail: String,
        pressure: PressureLevel,
        values: [Double],
        drawsGraph: Bool,
        theme: SearoomTheme
    ) {
        drawCardFrame(rect, theme: theme)
        let color = theme.color(for: pressure)
        drawText(title, at: NSPoint(x: rect.minX + 10, y: rect.minY + 10), font: SearoomFont.metric(10), color: theme.subdued)
        drawText(
            pressure.label,
            alignedRightAt: rect.maxX - 10,
            y: rect.minY + 10,
            font: SearoomFont.metric(8),
            color: color
        )
        drawText(
            value,
            in: NSRect(x: rect.minX + 10, y: rect.minY + 32, width: rect.width - 20, height: 24),
            font: SearoomFont.metric(20),
            color: theme.ink
        )
        drawText(
            detail,
            in: NSRect(x: rect.minX + 10, y: rect.minY + 59, width: rect.width - 20, height: 12),
            font: SearoomFont.metric(7.5),
            color: theme.subdued
        )
        let graphRect = NSRect(x: rect.minX + 10, y: rect.minY + 81, width: rect.width - 20, height: 65)
        if drawsGraph {
            drawGraph(
                values: values,
                rect: graphRect,
                color: color,
                theme: theme
            )
        }
    }

    private func drawNetworkCard(
        rect: NSRect,
        sample: SystemSample,
        downloads: [Double],
        uploads: [Double],
        drawsGraph: Bool,
        theme: SearoomTheme
    ) {
        drawCardFrame(rect, theme: theme)
        drawText("NETWORK I/O", at: NSPoint(x: rect.minX + 10, y: rect.minY + 10), font: SearoomFont.metric(10), color: theme.subdued)
        drawText(
            "↓ \(MetricFormat.rate(sample.networkDownloadPerSecond))",
            at: NSPoint(x: rect.minX + 10, y: rect.minY + 32),
            font: SearoomFont.metric(15),
            color: theme.cool
        )
        drawText(
            "↑ \(MetricFormat.rate(sample.networkUploadPerSecond))",
            at: NSPoint(x: rect.midX + 8, y: rect.minY + 32),
            font: SearoomFont.metric(15),
            color: theme.ink
        )

        let graphRect = NSRect(x: rect.minX + 10, y: rect.minY + 62, width: rect.width - 20, height: 48)
        if drawsGraph {
            drawDualGraph(
                first: downloads,
                second: uploads,
                rect: graphRect,
                firstColor: theme.cool,
                secondColor: theme.ink,
                theme: theme
            )
        }
    }

    private func drawInfoPair(
        rect: NSRect,
        leftTitle: String,
        leftValue: String,
        rightTitle: String,
        rightValue: String,
        theme: SearoomTheme
    ) {
        drawCardFrame(rect, theme: theme)
        theme.ink.withAlphaComponent(0.22).setFill()
        NSRect(x: rect.midX, y: rect.minY + 10, width: 1, height: rect.height - 20).fill()
        let valueY = rect.minY + 38
        let leftValueRect = NSRect(
            x: rect.minX + 10,
            y: valueY,
            width: rect.midX - rect.minX - 22,
            height: rect.maxY - valueY - 8
        )
        let rightValueRect = NSRect(
            x: rect.midX + 12,
            y: valueY,
            width: rect.maxX - rect.midX - 22,
            height: rect.maxY - valueY - 8
        )
        drawText(leftTitle, at: NSPoint(x: rect.minX + 10, y: rect.minY + 12), font: SearoomFont.metric(9), color: theme.subdued)
        drawText(leftValue, in: leftValueRect, font: SearoomFont.metric(15), color: theme.ink)
        drawText(rightTitle, at: NSPoint(x: rect.midX + 12, y: rect.minY + 12), font: SearoomFont.metric(9), color: theme.subdued)
        drawText(rightValue, in: rightValueRect, font: SearoomFont.metric(15), color: theme.ink)
    }

    private func drawSelfCard(rect: NSRect, sample: SystemSample, theme: SearoomTheme) {
        drawCardFrame(rect, theme: theme)
        let stripe = NSBezierPath(rect: NSRect(x: rect.minX, y: rect.minY, width: 5, height: rect.height))
        DitherPattern.fill(stripe, color: theme.nominal, density: 0.5)
        let summary = "SEAROOM · CPU \(MetricFormat.unboundedPercent(sample.processCPUUsage))"
            + " · RAM \(MetricFormat.compactBytes(sample.processMemoryBytes))"
            + " · SAMPLE \(String(format: "%.0f", model.settings.sampleInterval))S"
        drawText(
            summary,
            at: NSPoint(x: rect.minX + 14, y: rect.minY + 14),
            font: SearoomFont.metric(10.5),
            color: theme.ink
        )
    }

    private func drawExtrasCard(rect: NSRect, sample: SystemSample, theme: SearoomTheme) {
        drawCardFrame(rect, theme: theme)
        drawText("ENGINE ROOM", at: NSPoint(x: rect.minX + 10, y: rect.minY + 10), font: SearoomFont.metric(10), color: theme.subdued)
        let powerSource: String = switch (sample.isOnExternalPower, sample.batteryPercent) {
        case (true, _): "AC"
        case (false, let percent?): "BAT \(MetricFormat.percent(percent))"
        case (nil, let percent?): "BAT \(MetricFormat.percent(percent))"
        default: "N/A"
        }
        let power = "\(powerSource) · LPM \(sample.isLowPowerModeEnabled ? "ON" : "OFF")"
        let rows = [
            ("DISK READ", MetricFormat.rate(sample.diskReadPerSecond), "DISK WRITE", MetricFormat.rate(sample.diskWritePerSecond)),
            ("CACHE", MetricFormat.bytes(sample.memoryCached), "SWAP", MetricFormat.bytes(sample.swapUsed)),
            ("SWAP IN", MetricFormat.rate(sample.swapInPerSecond), "SWAP OUT", MetricFormat.rate(sample.swapOutPerSecond)),
            ("PROCESSES", "\(sample.processCount)", "POWER", power)
        ]
        for (index, row) in rows.enumerated() {
            let y = rect.minY + 36 + CGFloat(index * 27)
            drawText(row.0, at: NSPoint(x: rect.minX + 10, y: y), font: SearoomFont.metric(8), color: theme.subdued)
            drawText(row.1, at: NSPoint(x: rect.minX + 91, y: y - 1), font: SearoomFont.metric(10), color: theme.ink)
            drawText(row.2, at: NSPoint(x: rect.midX + 5, y: y), font: SearoomFont.metric(8), color: theme.subdued)
            drawText(row.3, alignedRightAt: rect.maxX - 10, y: y - 1, font: SearoomFont.metric(10), color: theme.ink)
        }
    }

    private func drawFooter(y: CGFloat, theme: SearoomTheme) {
        let margin: CGFloat = 12
        let gap: CGFloat = 8
        let buttonWidth = (bounds.width - margin * 2 - gap * 2) / 3
        settingsRect = NSRect(x: margin, y: y, width: buttonWidth, height: 38)
        activityMonitorRect = NSRect(
            x: settingsRect.maxX + gap,
            y: y,
            width: buttonWidth,
            height: 38
        )
        quitRect = NSRect(x: activityMonitorRect.maxX + gap, y: y, width: buttonWidth, height: 38)
        drawButton(rect: settingsRect, title: "SETTINGS  ⌘,", theme: theme)
        drawButton(rect: activityMonitorRect, title: "ACTIVITY MONITOR", theme: theme)
        drawButton(rect: quitRect, title: "QUIT  ⌘Q", theme: theme)
    }

    private func drawButton(rect: NSRect, title: String, theme: SearoomTheme) {
        theme.ink.withAlphaComponent(0.75).setStroke()
        let path = NSBezierPath(rect: rect.integral)
        path.lineWidth = 1
        path.stroke()
        let text = textSize(title, font: SearoomFont.metric(9))
        drawText(
            title,
            at: NSPoint(x: rect.midX - text.width / 2, y: rect.midY - text.height / 2),
            font: SearoomFont.metric(9),
            color: theme.ink
        )
    }

    private func drawCardFrame(_ rect: NSRect, theme: SearoomTheme) {
        theme.ink.withAlphaComponent(0.38).setStroke()
        let border = NSBezierPath(rect: rect.integral)
        border.lineWidth = 1
        border.stroke()
        let cap = NSBezierPath(rect: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 3))
        DitherPattern.fill(cap, color: theme.ink.withAlphaComponent(0.48), density: 0.5)
    }

    private func drawGraph(
        values: [Double],
        rect: NSRect,
        color: NSColor,
        theme: SearoomTheme
    ) {
        guard values.count > 1 else {
            drawText("COLLECTING TREND", at: NSPoint(x: rect.minX + 3, y: rect.midY - 5), font: SearoomFont.metric(7), color: theme.subdued)
            return
        }
        drawGrid(in: rect, theme: theme)
        let line = graphPath(values: values, rect: rect)
        let area = graphAreaPath(values: values, rect: rect)
        DitherPattern.fill(area, color: color.withAlphaComponent(0.72), density: 0.4)
        color.setStroke()
        line.lineWidth = 1.35
        line.stroke()
    }

    private func drawDualGraph(
        first: [Double],
        second: [Double],
        rect: NSRect,
        firstColor: NSColor,
        secondColor: NSColor,
        theme: SearoomTheme
    ) {
        guard max(first.count, second.count) > 1 else { return }
        drawGrid(in: rect, theme: theme)
        for (values, color, density) in [(first, firstColor, 0.42), (second, secondColor, 0.22)] {
            guard values.count > 1 else { continue }
            let area = graphAreaPath(values: values, rect: rect)
            DitherPattern.fill(area, color: color.withAlphaComponent(0.68), density: density)
            let line = graphPath(values: values, rect: rect)
            color.setStroke()
            line.lineWidth = 1.1
            line.stroke()
        }
    }

    private func drawGrid(in rect: NSRect, theme: SearoomTheme) {
        theme.ink.withAlphaComponent(0.14).setFill()
        for fraction in [0.25, 0.5, 0.75] {
            let y = rect.maxY - rect.height * fraction
            NSRect(x: rect.minX, y: y, width: rect.width, height: 1).fill()
        }
    }

    private func updateHoverOverlay() {
        guard let hoverState,
              !model.history.isEmpty,
              let region = graphRegions.first(where: { $0.metric == hoverState.metric }) else {
            hoverOverlay.hide()
            return
        }

        let sampleIndex = nearestSampleIndex(to: hoverState.sampleTimestamp)
        let sample = model.history[sampleIndex]
        let fraction: CGFloat
        if let graphCache {
            let duration = graphCache.endTimestamp.timeIntervalSince(graphCache.startTimestamp)
            fraction = duration > 0
                ? CGFloat(sample.timestamp.timeIntervalSince(graphCache.startTimestamp) / duration)
                : 0
        } else {
            let denominator = CGFloat(max(1, model.history.count - 1))
            fraction = CGFloat(sampleIndex) / denominator
        }
        let label = hoverLabel(metric: hoverState.metric, sample: sample)
        hoverOverlay.show(
            in: region.rect,
            x: min(1, max(0, fraction)) * region.rect.width,
            label: label
        )
    }

    private func hoverLabel(metric: HoverMetric, sample: SystemSample) -> String {
        let value: String = switch metric {
        case .cpu:
            "CPU \(MetricFormat.percent(sample.cpuUsage))"
        case .memory:
            "RAM \(MetricFormat.compactBytes(sample.memoryUsed))/\(MetricFormat.compactBytes(sample.memoryTotal))"
        case .gpu:
            "GPU \(sample.gpuUsage.map(MetricFormat.percent) ?? "N/A")"
        case .thermal:
            "\(sample.temperatureSource.compactLabel) \(MetricFormat.temperature(sample.temperatureCelsius))"
        case .network:
            "↓ \(MetricFormat.rate(sample.networkDownloadPerSecond)) · ↑ \(MetricFormat.rate(sample.networkUploadPerSecond))"
        }
        return "\(value) · \(Self.hoverTimeFormatter.string(from: sample.timestamp))"
    }

    private func clearHover() {
        NSCursor.arrow.set()
        guard hoverState != nil else { return }
        self.hoverState = nil
        hoverOverlay.hide()
    }

    private func hoverSampleIndex(at fraction: CGFloat) -> Int {
        guard let graphCache else {
            return min(
                model.history.count - 1,
                max(0, Int((fraction * CGFloat(model.history.count - 1)).rounded()))
            )
        }
        let duration = graphCache.endTimestamp.timeIntervalSince(graphCache.startTimestamp)
        let target = graphCache.startTimestamp.addingTimeInterval(duration * Double(fraction))
        return nearestSampleIndex(to: target)
    }

    private func nearestSampleIndex(to target: Date) -> Int {
        DashboardTrendSampleLocator.nearestIndex(
            to: target,
            count: model.history.count,
            timestampAt: { model.history[$0].timestamp }
        ) ?? 0
    }

    private func makeLivePresentation() -> LivePresentation {
        let sample = model.currentSample
        let fanText = MetricFormat.fanActivity(sample.fans)
        let thermalDetail = sample.fans.isEmpty
            ? "\(sample.temperatureSource.label) · FAN N/A"
            : "\(sample.temperatureSource.label) · "
                + sample.fans.map { "\(Int($0.rpm)) RPM" }.joined(separator: " · ")
        let power = "\(sample.batteryPercent.map(MetricFormat.percent) ?? "N/A")"
            + "-\(sample.isOnExternalPower.map(String.init) ?? "N/A")"
            + "-\(sample.isLowPowerModeEnabled)"
        return LivePresentation(
            header: sample.overallPressureLevel,
            cpu: "\(MetricFormat.percent(sample.cpuUsage))-\(sample.loadAverage1m)-\(sample.logicalCPUCount)-\(sample.cpuPressureLevel.rawValue)",
            memory: "\(sample.memoryUsed)-\(sample.memoryTotal)-\(sample.memoryAvailable)-\(sample.swapUsed)-\(sample.memoryPressureLevel.rawValue)",
            gpu: "\(sample.gpuUsage.map(MetricFormat.percent) ?? "N/A")-\(sample.gpuPressureLevel.rawValue)",
            thermal: "\(MetricFormat.temperature(sample.temperatureCelsius))-\(thermalDetail)-\(sample.thermalPressureLevel.rawValue)",
            network: "\(MetricFormat.rate(sample.networkDownloadPerSecond))-\(MetricFormat.rate(sample.networkUploadPerSecond))",
            info: "\(fanText)-\(MetricFormat.uptime(sample.uptime))",
            extras: "\(sample.diskReadPerSecond)-\(sample.diskWritePerSecond)-\(sample.memoryCached)-\(sample.swapUsed)-\(sample.swapInPerSecond)-\(sample.swapOutPerSecond)-\(sample.processCount)-\(power)",
            ownProcess: "\(MetricFormat.unboundedPercent(sample.processCPUUsage))-\(MetricFormat.compactBytes(sample.processMemoryBytes))-\(model.settings.sampleInterval)",
            pressures: [
                sample.cpuPressureLevel,
                sample.memoryPressureLevel,
                sample.gpuPressureLevel,
                sample.thermalPressureLevel
            ]
        )
    }

    private func invalidateChangedLiveRegions(
        from previous: LivePresentation,
        to current: LivePresentation
    ) {
        let margin: CGFloat = 12
        let gap: CGFloat = 10
        let cardWidth = (bounds.width - margin * 2 - gap) / 2
        let cpu = NSRect(x: margin, y: 82, width: cardWidth, height: 158)
        let memory = NSRect(x: margin + cardWidth + gap, y: 82, width: cardWidth, height: 158)
        let gpu = NSRect(x: margin, y: 250, width: cardWidth, height: 158)
        let thermal = NSRect(x: margin + cardWidth + gap, y: 250, width: cardWidth, height: 158)
        let network = NSRect(x: margin, y: 418, width: bounds.width - margin * 2, height: 122)

        if previous.header != current.header {
            invalidateVisible(NSRect(x: bounds.width * 0.5, y: 8, width: bounds.width * 0.5, height: 50))
        }
        if previous.cpu != current.cpu { invalidateVisible(liveMetricRect(for: cpu)) }
        if previous.memory != current.memory { invalidateVisible(liveMetricRect(for: memory)) }
        if previous.gpu != current.gpu { invalidateVisible(liveMetricRect(for: gpu)) }
        if previous.thermal != current.thermal { invalidateVisible(liveMetricRect(for: thermal)) }
        if previous.network != current.network {
            invalidateVisible(NSRect(x: network.minX + 2, y: network.minY + 5, width: network.width - 4, height: 54))
        }
        if previous.info != current.info {
            invalidateVisible(NSRect(x: margin + 2, y: 555, width: bounds.width - margin * 2 - 4, height: 78))
        }
        if previous.extras != current.extras {
            invalidateVisible(NSRect(x: margin + 2, y: 653, width: bounds.width - margin * 2 - 4, height: 143))
        }
        if previous.ownProcess != current.ownProcess {
            invalidateVisible(NSRect(x: margin + 7, y: 817, width: bounds.width - margin * 2 - 9, height: 31))
        }

        let cards = [cpu, memory, gpu, thermal]
        for index in cards.indices where previous.pressures[index] != current.pressures[index] {
            invalidateVisible(graphRect(for: cards[index]))
        }
    }

    private func invalidateTrendRegions() {
        let margin: CGFloat = 12
        let gap: CGFloat = 10
        let cardWidth = (bounds.width - margin * 2 - gap) / 2
        for card in [
            NSRect(x: margin, y: 82, width: cardWidth, height: 158),
            NSRect(x: margin + cardWidth + gap, y: 82, width: cardWidth, height: 158),
            NSRect(x: margin, y: 250, width: cardWidth, height: 158),
            NSRect(x: margin + cardWidth + gap, y: 250, width: cardWidth, height: 158)
        ] {
            invalidateVisible(graphRect(for: card))
        }
        let network = NSRect(x: margin, y: 418, width: bounds.width - margin * 2, height: 122)
        invalidateVisible(networkGraphRect(for: network))
    }

    private func invalidateVisible(_ rect: NSRect) {
        let visible = visibleRect
        guard rect.intersects(visible) else { return }
        setNeedsDisplay(rect.intersection(visible))
    }

    private func liveMetricRect(for cardRect: NSRect) -> NSRect {
        NSRect(
            x: cardRect.minX + 2,
            y: cardRect.minY + 5,
            width: cardRect.width - 4,
            height: 73
        )
    }

    private func graphRect(for cardRect: NSRect) -> NSRect {
        NSRect(
            x: cardRect.minX + 10,
            y: cardRect.minY + 81,
            width: cardRect.width - 20,
            height: 65
        )
    }

    private func networkGraphRect(for cardRect: NSRect) -> NSRect {
        NSRect(
            x: cardRect.minX + 10,
            y: cardRect.minY + 62,
            width: cardRect.width - 20,
            height: 48
        )
    }

    private func cachedGraphs(cardLimit: Int, networkLimit: Int) -> GraphCache {
        if let graphCache,
           graphCache.historyCount == model.history.count,
           graphCache.cardLimit == cardLimit,
           graphCache.networkLimit == networkLimit {
            return graphCache
        }

        var cpu: [Double] = []
        var memory: [Double] = []
        var gpu: [Double] = []
        var thermal: [Double] = []
        var download: [Double] = []
        var upload: [Double] = []
        let count = model.history.count
        for arrayIndex in 0..<count {
            let sample = model.history[arrayIndex]
            cpu.append(sample.cpuUsage)
            memory.append(Double(sample.memoryUsed) / Double(max(1, sample.memoryTotal)))
            if let value = sample.gpuUsage { gpu.append(value) }
            if let value = sample.temperatureCelsius { thermal.append(value) }
            download.append(sample.networkDownloadPerSecond)
            upload.append(sample.networkUploadPerSecond)
        }

        let networkMaximum = max(1, max(download.max() ?? 0, upload.max() ?? 0))
        let cache = GraphCache(
            historyCount: count,
            cardLimit: cardLimit,
            networkLimit: networkLimit,
            startTimestamp: model.history.first?.timestamp ?? .distantPast,
            endTimestamp: model.history.last?.timestamp ?? .distantPast,
            cpu: normalize(downsample(cpu, limit: cardLimit), scale: .percentage),
            memory: normalize(downsample(memory, limit: cardLimit), scale: .percentage),
            gpu: normalize(downsample(gpu, limit: cardLimit), scale: .percentage),
            thermal: normalize(downsample(thermal, limit: cardLimit), scale: .temperature),
            download: downsample(download, limit: networkLimit).map { $0 / networkMaximum },
            upload: downsample(upload, limit: networkLimit).map { $0 / networkMaximum }
        )
        graphCache = cache
        return cache
    }

    private func normalize(_ values: [Double], scale: GraphScale) -> [Double] {
        switch scale {
        case .percentage:
            values.map { min(1, max(0, $0)) }
        case .temperature:
            values.map { min(1, max(0, ($0 - 25) / 80)) }
        }
    }

    private func downsample(_ values: [Double], limit: Int) -> [Double] {
        guard limit > 1, values.count > limit else { return values }
        let bucketWidth = Double(values.count) / Double(limit)
        return (0..<limit).map { bucket in
            let lower = Int(Double(bucket) * bucketWidth)
            let upper = min(values.count, max(lower + 1, Int(Double(bucket + 1) * bucketWidth)))
            return values[lower..<upper].max() ?? 0
        }
    }

    private func graphPath(values: [Double], rect: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        let denominator = CGFloat(max(1, values.count - 1))
        for (index, value) in values.enumerated() {
            let point = NSPoint(
                x: rect.minX + CGFloat(index) / denominator * rect.width,
                y: rect.maxY - CGFloat(value) * rect.height
            )
            index == 0 ? path.move(to: point) : path.line(to: point)
        }
        return path
    }

    private func graphAreaPath(values: [Double], rect: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.maxY))
        let denominator = CGFloat(max(1, values.count - 1))
        for (index, value) in values.enumerated() {
            path.line(to: NSPoint(
                x: rect.minX + CGFloat(index) / denominator * rect.width,
                y: rect.maxY - CGFloat(value) * rect.height
            ))
        }
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        path.close()
        return path
    }

    private func density(for level: PressureLevel) -> Double {
        switch level {
        case .unavailable, .nominal: 0.25
        case .elevated: 0.45
        case .constrained: 0.7
        case .critical: 0.95
        }
    }

    private func updateAccessibilitySummary() {
        let sample = model.currentSample
        setAccessibilityValue(
            "System \(sample.overallPressureLevel.systemLabel). "
                + "CPU \(MetricFormat.percent(sample.cpuUsage)). "
                + "Memory \(MetricFormat.bytes(sample.memoryUsed)) used of \(MetricFormat.bytes(sample.memoryTotal)). "
                + "Temperature \(MetricFormat.temperature(sample.temperatureCelsius)). "
                + "Searoom uses \(MetricFormat.unboundedPercent(sample.processCPUUsage)) CPU and \(MetricFormat.bytes(sample.processMemoryBytes)) memory."
        )
    }

    private func drawText(_ text: String, at point: NSPoint, font: NSFont, color: NSColor) {
        (text as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
    }

    private func drawText(_ text: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        )
    }

    private func drawText(_ text: String, alignedRightAt x: CGFloat, y: CGFloat, font: NSFont, color: NSColor) {
        let size = textSize(text, font: font)
        drawText(text, at: NSPoint(x: x - size.width, y: y), font: font, color: color)
    }

    private func textSize(_ text: String, font: NSFont) -> NSSize {
        (text as NSString).size(withAttributes: [.font: font])
    }

    private enum GraphScale {
        case percentage
        case temperature
    }

    private enum HoverMetric: Equatable {
        case cpu
        case memory
        case gpu
        case thermal
        case network
    }

    private struct GraphRegion {
        let metric: HoverMetric
        let rect: NSRect
    }

    private struct HoverState: Equatable {
        let metric: HoverMetric
        let sampleTimestamp: Date
    }

    private struct LivePresentation: Equatable {
        let header: PressureLevel
        let cpu: String
        let memory: String
        let gpu: String
        let thermal: String
        let network: String
        let info: String
        let extras: String
        let ownProcess: String
        let pressures: [PressureLevel]
    }

    private struct GraphCache {
        let historyCount: Int
        let cardLimit: Int
        let networkLimit: Int
        let startTimestamp: Date
        let endTimestamp: Date
        let cpu: [Double]
        let memory: [Double]
        let gpu: [Double]
        let thermal: [Double]
        let download: [Double]
        let upload: [Double]
    }

    private static let hoverTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

@MainActor
private final class GraphHoverOverlayView: NSView {
    private var cursorX: CGFloat = 0
    private var label = ""

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        isHidden = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(in rect: NSRect, x: CGFloat, label: String) {
        frame = rect
        cursorX = min(bounds.width, max(0, x))
        self.label = label
        isHidden = false
        needsDisplay = true
    }

    func hide() {
        isHidden = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let theme = SearoomTheme(appearance: effectiveAppearance)
        theme.ink.withAlphaComponent(0.42).setFill()
        NSRect(x: floor(cursorX), y: 0, width: 1, height: bounds.height).fill()

        let font = SearoomFont.metric(8.5)
        let labelSize = (label as NSString).size(withAttributes: [.font: font])
        let tooltipWidth = min(bounds.width, labelSize.width + 10)
        let tooltipX = min(bounds.maxX - tooltipWidth, max(bounds.minX, cursorX - tooltipWidth / 2))
        let tooltip = NSRect(x: tooltipX, y: 3, width: tooltipWidth, height: 19).integral

        theme.paper.setFill()
        tooltip.fill()
        theme.ink.withAlphaComponent(0.72).setStroke()
        let outline = NSBezierPath(rect: tooltip)
        outline.lineWidth = 1
        outline.stroke()
        (label as NSString).draw(
            at: NSPoint(x: tooltip.minX + 5, y: tooltip.minY + 4),
            withAttributes: [.font: font, .foregroundColor: theme.ink]
        )
    }
}

@MainActor
final class DashboardViewController: NSViewController {
    let dashboardView: DashboardView

    init(model: AppModel) {
        dashboardView = DashboardView(model: model)
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 430, height: 720)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let scrollView = SearoomScrollView(frame: NSRect(origin: .zero, size: preferredContentSize))
        let clipView = SearoomClipView()
        let zeroInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        clipView.automaticallyAdjustsContentInsets = false
        clipView.contentInsets = zeroInsets
        scrollView.contentView = clipView
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = zeroInsets
        scrollView.scrollerInsets = zeroInsets
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.documentView = dashboardView
        self.view = scrollView
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        dashboardView.refresh(forceTrend: true)
    }
}

@MainActor
private final class SearoomScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaY) > 0.001 else { return }
        super.scrollWheel(with: event)
        lockHorizontalPosition()
    }

    override func layout() {
        super.layout()
        lockHorizontalPosition()
    }

    private func lockHorizontalPosition() {
        let origin = contentView.bounds.origin
        guard abs(origin.x) > 0.001 else { return }
        contentView.scroll(to: NSPoint(x: 0, y: origin.y))
        reflectScrolledClipView(contentView)
    }
}

@MainActor
private final class SearoomClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrained = super.constrainBoundsRect(proposedBounds)
        constrained.origin.x = 0
        return constrained
    }
}
