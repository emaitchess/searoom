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
    private var unitRegions: [UnitRegion] = []
    private var graphCache: GraphCache?
    private var hoverState: HoverState?
    private var hoverTrackingArea: NSTrackingArea?
    private var hoverOverlays: [DashboardTrendMetric: GraphHoverOverlayView] = [:]
    private let refreshClock = ContinuousClock()
    private var trendRefreshPolicy = DashboardTrendRefreshPolicy()
    private var livePresentation: LivePresentation?
    private var cachedLayout: DashboardLayout?
    private var cachedLayoutWidth: CGFloat = 0
    private var cachedLayoutOrder: [DashboardSection] = []
    private var dragCandidate: DragCandidate?
    private var pendingUnitRegion: UnitRegion?
    private var activeDrag: ActiveDrag?

    /// Far enough that a click that wobbles is still a click.
    private static let dragThreshold: CGFloat = 4

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(model: AppModel) {
        self.model = model
        // The document height depends on the section order, so it is derived
        // rather than the literal 1120 this view used to carry.
        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: 430,
            height: DashboardLayout.make(
                order: model.settings.dashboardSectionOrder,
                width: 430
            ).contentHeight
        ))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Searoom system dashboard")
        for metric in DashboardTrendMetric.allCases {
            let overlay = GraphHoverOverlayView()
            addSubview(overlay)
            hoverOverlays[metric] = overlay
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// One layout per (order, width), rebuilt only when either changes, so the
    /// draw path does no geometry work on an ordinary sampling tick.
    private func currentLayout() -> DashboardLayout {
        let order = model.settings.dashboardSectionOrder
        if let cachedLayout, cachedLayoutWidth == bounds.width, cachedLayoutOrder == order {
            return cachedLayout
        }
        let layout = DashboardLayout.make(order: order, width: bounds.width)
        cachedLayout = layout
        cachedLayoutWidth = bounds.width
        cachedLayoutOrder = order
        return layout
    }

    /// A full-width section placed after an odd number of half-width cards
    /// leaves half a row empty, so reordering can change the document height.
    private func syncContentHeight() {
        let height = currentLayout().contentHeight
        guard abs(frame.height - height) > 0.5 else { return }
        setFrameSize(NSSize(width: frame.width, height: height))
        needsDisplay = true
    }

    func refresh(forceTrend: Bool = false) {
        syncContentHeight()
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
        hoverOverlays.values.forEach { $0.hide() }
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
        let layout = currentLayout()
        let headerRect = NSRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: DashboardLayout.headerHeight
        )
        let cpuRect = layout.rect(for: .cpu) ?? .zero
        let memoryRect = layout.rect(for: .memory) ?? .zero
        let gpuRect = layout.rect(for: .gpu) ?? .zero
        let thermalRect = layout.rect(for: .thermal) ?? .zero
        let gpuMemoryRect = layout.rect(for: .gpuMemory) ?? .zero
        let diskRect = layout.rect(for: .disk) ?? .zero
        let networkRect = layout.rect(for: .network) ?? .zero
        let infoRect = layout.rect(for: .info) ?? .zero
        let extrasRect = layout.rect(for: .extras) ?? .zero
        let selfRect = layout.selfRect
        let footerRect = layout.footerRect
        graphRegions = [
            GraphRegion(metric: .cpu, rect: graphRect(for: cpuRect)),
            GraphRegion(metric: .memory, rect: graphRect(for: memoryRect)),
            GraphRegion(metric: .gpu, rect: graphRect(for: gpuRect)),
            GraphRegion(metric: .thermal, rect: graphRect(for: thermalRect)),
            GraphRegion(metric: .gpuMemory, rect: graphRect(for: gpuMemoryRect)),
            GraphRegion(metric: .diskUsed, rect: graphRect(for: diskRect)),
            GraphRegion(metric: .network, rect: networkGraphRect(for: networkRect))
        ]
        unitRegions = makeUnitRegions(
            memoryRect: memoryRect,
            thermalRect: thermalRect,
            gpuMemoryRect: gpuMemoryRect,
            diskRect: diskRect,
            networkRect: networkRect,
            extrasRect: extrasRect,
            selfRect: selfRect,
            sample: sample
        )
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
            value: MetricFormat.bytePair(
                sample.memoryUsed,
                sample.memoryTotal,
                unit: model.dashboardUnitState.byteUnit(for: .memory)
            ),
            detail: "FREE \(MetricFormat.compactBytes(sample.memoryAvailable, unit: model.dashboardUnitState.byteUnit(for: .memory)))"
                + " · SWAP \(MetricFormat.compactBytes(sample.swapUsed, unit: model.dashboardUnitState.byteUnit(for: .memory)))"
                + " · COMP \(MetricFormat.compactBytes(sample.compressedMemoryBytes, unit: model.dashboardUnitState.byteUnit(for: .memory)))",
            pressure: sample.memoryPressureLevel,
            secondaryValues: graphs?.compressed ?? [],
            secondaryColor: theme.cool,
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
            value: MetricFormat.temperature(
                sample.temperatureCelsius,
                unit: model.dashboardUnitState.temperatureUnit(for: .temperature)
            ),
            detail: sample.fans.isEmpty
                ? "\(sample.temperatureSource.label) · FAN N/A"
                : "\(sample.temperatureSource.label) · "
                    + sample.fans.map { "\(Int($0.rpm)) RPM" }.joined(separator: " · "),
            pressure: sample.thermalPressureLevel,
            values: graphs?.thermal ?? [],
            drawsGraph: needsToDraw(graphRect(for: thermalRect)),
            theme: theme
        ) }

        let gpuMemoryUnit = model.dashboardUnitState.byteUnit(for: .gpuMemory)
        let gpuMemoryCardValue = if let used = sample.gpuMemoryUsedBytes, let recommended = sample.gpuMemoryRecommendedBytes {
            MetricFormat.bytePair(used, recommended, unit: gpuMemoryUnit)
        } else if let used = sample.gpuMemoryUsedBytes {
            MetricFormat.compactBytes(used, unit: gpuMemoryUnit)
        } else {
            "N/A"
        }
        let gpuMemoryCardDetail = if sample.gpuMemoryUsedBytes == nil {
            "SENSOR UNAVAILABLE"
        } else if sample.gpuMemoryRecommendedBytes == nil {
            "WORKING SET BUDGET UNAVAILABLE"
        } else {
            "\(MetricFormat.percent(sample.gpuMemoryPressure ?? 0)) OF RECOMMENDED WORKING SET"
        }
        if needsToDraw(gpuMemoryRect) { drawMetricCard(
            rect: gpuMemoryRect,
            title: "GPU MEMORY",
            value: gpuMemoryCardValue,
            detail: gpuMemoryCardDetail,
            pressure: sample.gpuPressureLevel,
            values: graphs?.gpuMemory ?? [],
            drawsGraph: needsToDraw(graphRect(for: gpuMemoryRect)),
            theme: theme
        ) }
        let diskCapacityUnit = model.dashboardUnitState.byteUnit(for: .diskCapacity)
        let diskCardValue = sample.diskAvailableBytes.map {
            MetricFormat.compactBytes($0, unit: diskCapacityUnit)
        } ?? "N/A"
        let diskCardDetail = sample.diskCapacityBytes.map {
            "OF \(MetricFormat.compactBytes($0, unit: diskCapacityUnit))"
        } ?? "CAPACITY UNAVAILABLE"
        if needsToDraw(diskRect) { drawMetricCard(
            rect: diskRect,
            title: "DISK",
            value: diskCardValue,
            detail: diskCardDetail,
            pressure: nil,
            values: graphs?.diskUsed ?? [],
            drawsGraph: needsToDraw(graphRect(for: diskRect)),
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
        if needsToDraw(footerRect) { drawFooter(y: footerRect.minY, theme: theme) }
        if let activeDrag { drawDragAffordance(activeDrag, theme: theme) }
        if needsGraphs { updateHoverOverlays() }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if settingsRect.contains(point) { onOpenSettings?(); return }
        if activityMonitorRect.contains(point) { onOpenActivityMonitor?(); return }
        if quitRect.contains(point) { onQuit?(); return }

        // A press over a card is ambiguous, so nothing is decided here. Several
        // unit hit rects are the whole card - memory, thermal, GPU memory, disk
        // and network all are - so cycling units on the press would make those
        // cards impossible to drag. Both intents are recorded and resolved on
        // release: a drag past the threshold wins, otherwise it was a click.
        pendingUnitRegion = unitRegions.first { $0.hitRect.contains(point) }
        dragCandidate = currentLayout().slots
            .first { $0.rect.contains(point) }
            .map { DragCandidate(section: $0.section, origin: point, rect: $0.rect) }
        if pendingUnitRegion == nil, dragCandidate == nil {
            super.mouseDown(with: event)
        }
    }

    private func cycleUnits(_ region: UnitRegion) {
        model.cycleDashboardUnit(region.target)
        livePresentation = makeLivePresentation()
        invalidateVisible(region.displayRect)
        updateHoverOverlays()
        updateAccessibilitySummary()
        setAccessibilityHelp(
            "\(region.target.accessibilityName.capitalized) display unit: "
                + "\(model.dashboardUnitState.unitLabel(for: region.target))."
        )
    }

    override func mouseDragged(with event: NSEvent) {
        guard let candidate = dragCandidate else {
            super.mouseDragged(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if activeDrag == nil {
            let travelled = hypot(point.x - candidate.origin.x, point.y - candidate.origin.y)
            guard travelled >= Self.dragThreshold else { return }
            // Past the threshold this is a drag, so the click it might have
            // been is abandoned and no unit rotates on release.
            pendingUnitRegion = nil
            clearHover()
            NSCursor.closedHand.set()
            activeDrag = ActiveDrag(
                section: candidate.section,
                rect: candidate.rect,
                grabOffset: NSPoint(
                    x: candidate.origin.x - candidate.rect.minX,
                    y: candidate.origin.y - candidate.rect.minY
                ),
                point: point,
                insertionIndex: 0
            )
        }
        activeDrag?.point = point
        activeDrag?.insertionIndex = currentLayout().insertionIndex(
            for: point,
            excluding: candidate.section
        )
        // Lets a drag reach a section scrolled out of view. The clip view still
        // refuses horizontal movement, so this cannot drift the x origin.
        autoscroll(with: event)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag = activeDrag else {
            dragCandidate = nil
            if let region = pendingUnitRegion {
                pendingUnitRegion = nil
                cycleUnits(region)
                return
            }
            super.mouseUp(with: event)
            return
        }
        dragCandidate = nil
        pendingUnitRegion = nil
        activeDrag = nil
        NSCursor.arrow.set()
        // Releasing outside the dashboard abandons the move rather than
        // dropping the card at whatever edge the pointer happened to leave by.
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            commitDrag(drag)
        }
        needsDisplay = true
    }

    override func cancelOperation(_ sender: Any?) {
        guard activeDrag != nil else {
            super.cancelOperation(sender)
            return
        }
        dragCandidate = nil
        pendingUnitRegion = nil
        activeDrag = nil
        NSCursor.arrow.set()
        needsDisplay = true
    }

    private func commitDrag(_ drag: ActiveDrag) {
        let reordered = DashboardSection.reordered(
            model.settings.dashboardSectionOrder,
            moving: drag.section,
            to: drag.insertionIndex
        )
        guard reordered != model.settings.dashboardSectionOrder else { return }
        model.setDashboardSectionOrder(reordered)
        syncContentHeight()
        updateAccessibilitySummary()
        setAccessibilityHelp("\(drag.section.title) moved to position \(drag.insertionIndex + 1).")
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }


    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let region = graphRegions.first(where: { $0.rect.contains(point) }),
           !model.history.isEmpty {
            let fraction = min(1, max(0, (point.x - region.rect.minX) / max(1, region.rect.width)))
            let index = hoverSampleIndex(at: fraction)
            let nextState = HoverState(
                metric: region.metric,
                sampleTimestamp: model.history[index].timestamp
            )
            NSCursor.crosshair.set()
            guard nextState != hoverState else { return }
            hoverState = nextState
            updateHoverOverlays()
            return
        }

        clearHover()
        if unitRegions.contains(where: { $0.hitRect.contains(point) }) {
            NSCursor.pointingHand.set()
        }
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
        let durationText = headerDurationText()
        if !durationText.isEmpty {
            drawText(
                durationText,
                alignedRightAt: statusRect.maxX,
                y: 49,
                font: SearoomFont.metric(8),
                color: theme.subdued
            )
        }
        theme.ink.withAlphaComponent(0.65).setFill()
        NSRect(x: 0, y: 67, width: bounds.width, height: 1).fill()
    }

    /// The sustained-duration line under the header status box. Hidden until
    /// the level has been held for at least a minute; a run that spans every
    /// retained sample is suffixed with `+` because the window, not the Mac,
    /// bounds it.
    private func headerDurationText() -> String {
        guard let sustained = SustainedPressure.duration(in: model.history),
              sustained.duration >= 60
        else { return "" }
        return "FOR \(MetricFormat.compactDuration(sustained.duration))"
            + (sustained.boundedByHistoryWindow ? "+" : "")
    }

    private func drawMetricCard(
        rect: NSRect,
        title: String,
        value: String,
        detail: String,
        pressure: PressureLevel?,
        secondaryValues: [Double] = [],
        secondaryColor: NSColor? = nil,
        values: [Double],
        drawsGraph: Bool,
        theme: SearoomTheme
    ) {
        drawCardFrame(rect, theme: theme)
        let color = pressure.map { theme.color(for: $0) } ?? theme.cool
        drawText(title, at: NSPoint(x: rect.minX + 10, y: rect.minY + 10), font: SearoomFont.metric(10), color: theme.subdued)
        if let pressure {
            drawText(
                pressure.label,
                alignedRightAt: rect.maxX - 10,
                y: rect.minY + 10,
                font: SearoomFont.metric(8),
                color: color
            )
        }
        let valueRect = NSRect(
            x: rect.minX + 10,
            y: rect.minY + 32,
            width: rect.width - 20,
            height: 24
        )
        drawText(
            value,
            in: valueRect,
            font: fittedMetricFont(value, maximumSize: 20, minimumSize: 12, width: valueRect.width),
            color: theme.ink
        )
        let detailRect = NSRect(
            x: rect.minX + 10,
            y: rect.minY + 59,
            width: rect.width - 20,
            height: 12
        )
        drawText(
            detail,
            in: detailRect,
            font: fittedMetricFont(detail, maximumSize: 7.5, minimumSize: 6, width: detailRect.width),
            color: theme.subdued
        )
        let graphRect = NSRect(x: rect.minX + 10, y: rect.minY + 81, width: rect.width - 20, height: 65)
        if drawsGraph {
            if let secondaryColor, secondaryValues.count > 1 {
                drawDualGraph(
                    first: values,
                    second: secondaryValues,
                    rect: graphRect,
                    firstColor: color,
                    secondColor: secondaryColor,
                    theme: theme
                )
            } else {
                drawGraph(
                    values: values,
                    rect: graphRect,
                    color: color,
                    theme: theme
                )
            }
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
        let rateUnit = model.dashboardUnitState.rateUnit(for: .network)
        drawText("NETWORK I/O", at: NSPoint(x: rect.minX + 10, y: rect.minY + 10), font: SearoomFont.metric(10), color: theme.subdued)
        let download = "↓ \(MetricFormat.rate(sample.networkDownloadPerSecond, unit: rateUnit))"
        let upload = "↑ \(MetricFormat.rate(sample.networkUploadPerSecond, unit: rateUnit))"
        let downloadRect = NSRect(
            x: rect.minX + 10,
            y: rect.minY + 32,
            width: rect.midX - rect.minX - 18,
            height: 20
        )
        let uploadRect = NSRect(
            x: rect.midX + 8,
            y: rect.minY + 32,
            width: rect.maxX - rect.midX - 18,
            height: 20
        )
        drawText(
            download,
            in: downloadRect,
            font: fittedMetricFont(download, maximumSize: 15, minimumSize: 10, width: downloadRect.width),
            color: theme.cool
        )
        drawText(
            upload,
            in: uploadRect,
            font: fittedMetricFont(upload, maximumSize: 15, minimumSize: 10, width: uploadRect.width),
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
            + " · RAM \(MetricFormat.compactBytes(sample.processMemoryBytes, unit: model.dashboardUnitState.byteUnit(for: .processMemory)))"
            + " · SAMPLE \(String(format: "%.0f", model.settings.sampleInterval))S"
        let summaryRect = NSRect(
            x: rect.minX + 14,
            y: rect.minY + 12,
            width: rect.width - 28,
            height: 18
        )
        drawText(
            summary,
            in: summaryRect,
            font: fittedMetricFont(summary, maximumSize: 10.5, minimumSize: 8.5, width: summaryRect.width),
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
        let diskUnit = model.dashboardUnitState.rateUnit(for: .diskIO)
        let cacheUnit = model.dashboardUnitState.byteUnit(for: .cache)
        let swapUnit = model.dashboardUnitState.byteUnit(for: .swap)
        let swapIOUnit = model.dashboardUnitState.rateUnit(for: .swapIO)
        let compressedUnit = model.dashboardUnitState.byteUnit(for: .compressedMemory)
        let compressionUnit = model.dashboardUnitState.rateUnit(for: .compression)
        let compressionRates = "\(MetricFormat.rate(sample.compressionBytesPerSecond, unit: compressionUnit))"
            + " · \(MetricFormat.rate(sample.decompressionBytesPerSecond, unit: compressionUnit))"
        let rows = [
            (
                "DISK READ",
                MetricFormat.rate(sample.diskReadPerSecond, unit: diskUnit),
                "DISK WRITE",
                MetricFormat.rate(sample.diskWritePerSecond, unit: diskUnit)
            ),
            (
                "CACHE",
                MetricFormat.bytes(sample.memoryCached, unit: cacheUnit),
                "SWAP",
                MetricFormat.bytes(sample.swapUsed, unit: swapUnit)
            ),
            (
                "SWAP IN",
                MetricFormat.rate(sample.swapInPerSecond, unit: swapIOUnit),
                "SWAP OUT",
                MetricFormat.rate(sample.swapOutPerSecond, unit: swapIOUnit)
            ),
            (
                "COMPRESSED",
                MetricFormat.bytes(sample.compressedMemoryBytes, unit: compressedUnit),
                "COMP RATE",
                compressionRates
            ),
            ("PROCESSES", "\(sample.processCount)", "POWER", power)
        ]
        let labelFont = SearoomFont.metric(8)
        for (index, row) in rows.enumerated() {
            let y = rect.minY + 36 + CGFloat(index * 27)
            let leftValueRect = NSRect(
                x: rect.minX + 91,
                y: y - 1,
                width: rect.midX - rect.minX - 99,
                height: 14
            )
            let rightLabelX = rect.midX + 5
            let rightValueX = rightLabelX + textSize(row.2, font: labelFont).width + 8
            let rightValueRect = NSRect(
                x: rightValueX,
                y: y - 1,
                width: rect.maxX - 10 - rightValueX,
                height: 14
            )
            drawText(row.0, at: NSPoint(x: rect.minX + 10, y: y), font: labelFont, color: theme.subdued)
            drawText(
                row.1,
                in: leftValueRect,
                font: fittedMetricFont(row.1, maximumSize: 10, minimumSize: 7, width: leftValueRect.width),
                color: theme.ink
            )
            drawText(row.2, at: NSPoint(x: rightLabelX, y: y), font: labelFont, color: theme.subdued)
            drawText(
                row.3,
                in: rightValueRect,
                font: fittedMetricFont(row.3, maximumSize: 10, minimumSize: 7, width: rightValueRect.width),
                color: theme.ink,
                alignment: .right
            )
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

    /// Flat, as DESIGN.md requires: a hairline rule marks where the card will
    /// land and the dragged card is a plain outline under the pointer. No
    /// shadow, no scaling, no animation.
    private func drawDragAffordance(_ drag: ActiveDrag, theme: SearoomTheme) {
        if let indicator = dropIndicatorRect(for: drag) {
            theme.ink.withAlphaComponent(0.7).setFill()
            indicator.fill()
        }

        let ghost = NSRect(
            x: drag.point.x - drag.grabOffset.x,
            y: drag.point.y - drag.grabOffset.y,
            width: drag.rect.width,
            height: drag.rect.height
        )
        theme.paper.withAlphaComponent(0.92).setFill()
        ghost.fill()
        drawCardFrame(ghost, theme: theme)
        drawText(
            drag.section.title.uppercased(),
            at: NSPoint(x: ghost.minX + 10, y: ghost.minY + 10),
            font: SearoomFont.metric(10),
            color: theme.subdued
        )
    }

    /// Where the card would actually land, taken from a layout of the proposed
    /// order rather than guessed, so the rule cannot promise a position the
    /// drop will not produce.
    private func dropIndicatorRect(for drag: ActiveDrag) -> NSRect? {
        let proposed = DashboardSection.reordered(
            model.settings.dashboardSectionOrder,
            moving: drag.section,
            to: drag.insertionIndex
        )
        let layout = DashboardLayout.make(order: proposed, width: bounds.width)
        guard let rect = layout.rect(for: drag.section) else { return nil }
        return NSRect(x: rect.minX, y: rect.minY - 3, width: rect.width, height: 2)
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

    private func updateHoverOverlays() {
        guard let hoverState,
              !model.history.isEmpty else {
            hoverOverlays.values.forEach { $0.hide() }
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
        let visibleMetrics = hoverState.metric.synchronizedMetrics
        for metric in DashboardTrendMetric.allCases {
            guard visibleMetrics.contains(metric),
                  let region = graphRegions.first(where: { $0.metric == metric }),
                  let overlay = hoverOverlays[metric] else {
                hoverOverlays[metric]?.hide()
                continue
            }
            overlay.show(
                in: region.rect,
                x: min(1, max(0, fraction)) * region.rect.width,
                label: hoverLabel(metric: metric, sample: sample)
            )
        }
    }

    private func hoverLabel(metric: DashboardTrendMetric, sample: SystemSample) -> String {
        let memory = MetricFormat.bytePair(
            sample.memoryUsed,
            sample.memoryTotal,
            unit: model.dashboardUnitState.byteUnit(for: .memory)
        )
        let temperature = MetricFormat.temperature(
            sample.temperatureCelsius,
            unit: model.dashboardUnitState.temperatureUnit(for: .temperature)
        )
        let networkUnit = model.dashboardUnitState.rateUnit(for: .network)
        let download = MetricFormat.rate(sample.networkDownloadPerSecond, unit: networkUnit)
        let upload = MetricFormat.rate(sample.networkUploadPerSecond, unit: networkUnit)
        let gpuMemoryUnit = model.dashboardUnitState.byteUnit(for: .gpuMemory)
        let gpuMemory = if let used = sample.gpuMemoryUsedBytes, let recommended = sample.gpuMemoryRecommendedBytes {
            MetricFormat.bytePair(used, recommended, unit: gpuMemoryUnit)
        } else if let used = sample.gpuMemoryUsedBytes {
            MetricFormat.compactBytes(used, unit: gpuMemoryUnit)
        } else {
            "N/A"
        }
        let diskCapacityUnit = model.dashboardUnitState.byteUnit(for: .diskCapacity)
        let diskAvailable = sample.diskAvailableBytes.map {
            MetricFormat.compactBytes($0, unit: diskCapacityUnit)
        } ?? "N/A"
        let value: String = switch metric {
        case .cpu:
            "CPU \(MetricFormat.percent(sample.cpuUsage))"
        case .memory:
            "RAM \(memory)"
        case .gpu:
            "GPU \(sample.gpuUsage.map(MetricFormat.percent) ?? "N/A")"
        case .thermal:
            "\(sample.temperatureSource.compactLabel) \(temperature)"
        case .gpuMemory:
            "VRAM \(gpuMemory)"
        case .diskUsed:
            "DISK \(diskAvailable) FREE"
        case .network:
            "↓ \(download) · ↑ \(upload)"
        }
        return "\(value) · \(Self.hoverTimeFormatter.string(from: sample.timestamp))"
    }

    private func clearHover() {
        NSCursor.arrow.set()
        guard hoverState != nil else { return }
        self.hoverState = nil
        hoverOverlays.values.forEach { $0.hide() }
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
        let memoryUnit = model.dashboardUnitState.byteUnit(for: .memory)
        let temperatureUnit = model.dashboardUnitState.temperatureUnit(for: .temperature)
        let networkUnit = model.dashboardUnitState.rateUnit(for: .network)
        let diskUnit = model.dashboardUnitState.rateUnit(for: .diskIO)
        let cacheUnit = model.dashboardUnitState.byteUnit(for: .cache)
        let swapUnit = model.dashboardUnitState.byteUnit(for: .swap)
        let swapIOUnit = model.dashboardUnitState.rateUnit(for: .swapIO)
        let compressedUnit = model.dashboardUnitState.byteUnit(for: .compressedMemory)
        let compressionUnit = model.dashboardUnitState.rateUnit(for: .compression)
        let processMemoryUnit = model.dashboardUnitState.byteUnit(for: .processMemory)
        let gpuMemoryUnit = model.dashboardUnitState.byteUnit(for: .gpuMemory)
        let diskCapacityUnit = model.dashboardUnitState.byteUnit(for: .diskCapacity)
        let gpuMemory = if let used = sample.gpuMemoryUsedBytes, let recommended = sample.gpuMemoryRecommendedBytes {
            MetricFormat.bytePair(used, recommended, unit: gpuMemoryUnit)
        } else if let used = sample.gpuMemoryUsedBytes {
            MetricFormat.compactBytes(used, unit: gpuMemoryUnit)
        } else {
            "N/A"
        }
        let diskAvailable = sample.diskAvailableBytes.map {
            MetricFormat.compactBytes($0, unit: diskCapacityUnit)
        } ?? "N/A"
        let diskCapacity = sample.diskCapacityBytes.map {
            MetricFormat.compactBytes($0, unit: diskCapacityUnit)
        } ?? "N/A"
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
            headerDuration: headerDurationText(),
            cpu: "\(MetricFormat.percent(sample.cpuUsage))-\(sample.loadAverage1m)-\(sample.logicalCPUCount)-\(sample.cpuPressureLevel.rawValue)",
            memory: "\(MetricFormat.bytePair(sample.memoryUsed, sample.memoryTotal, unit: memoryUnit))"
                + "-\(MetricFormat.compactBytes(sample.memoryAvailable, unit: memoryUnit))"
                + "-\(MetricFormat.compactBytes(sample.swapUsed, unit: memoryUnit))"
                + "-\(MetricFormat.compactBytes(sample.compressedMemoryBytes, unit: memoryUnit))"
                + "-\(sample.memoryPressureLevel.rawValue)",
            gpu: "\(sample.gpuUsage.map(MetricFormat.percent) ?? "N/A")-\(sample.gpuPressureLevel.rawValue)",
            gpuMemory: "\(gpuMemory)-\(sample.gpuPressureLevel.rawValue)",
            disk: "\(diskAvailable)-\(diskCapacity)",
            thermal: "\(MetricFormat.temperature(sample.temperatureCelsius, unit: temperatureUnit))-\(thermalDetail)-\(sample.thermalPressureLevel.rawValue)",
            network: "\(MetricFormat.rate(sample.networkDownloadPerSecond, unit: networkUnit))"
                + "-\(MetricFormat.rate(sample.networkUploadPerSecond, unit: networkUnit))",
            info: "\(fanText)-\(MetricFormat.uptime(sample.uptime))",
            extras: "\(MetricFormat.rate(sample.diskReadPerSecond, unit: diskUnit))"
                + "-\(MetricFormat.rate(sample.diskWritePerSecond, unit: diskUnit))"
                + "-\(MetricFormat.bytes(sample.memoryCached, unit: cacheUnit))"
                + "-\(MetricFormat.bytes(sample.swapUsed, unit: swapUnit))"
                + "-\(MetricFormat.rate(sample.swapInPerSecond, unit: swapIOUnit))"
                + "-\(MetricFormat.rate(sample.swapOutPerSecond, unit: swapIOUnit))"
                + "-\(MetricFormat.bytes(sample.compressedMemoryBytes, unit: compressedUnit))"
                + "-\(MetricFormat.rate(sample.compressionBytesPerSecond, unit: compressionUnit))"
                + "-\(MetricFormat.rate(sample.decompressionBytesPerSecond, unit: compressionUnit))"
                + "-\(sample.processCount)-\(power)",
            ownProcess: "\(MetricFormat.unboundedPercent(sample.processCPUUsage))"
                + "-\(MetricFormat.compactBytes(sample.processMemoryBytes, unit: processMemoryUnit))"
                + "-\(model.settings.sampleInterval)",
            pressures: [
                sample.cpuPressureLevel,
                sample.memoryPressureLevel,
                sample.gpuPressureLevel,
                sample.thermalPressureLevel,
                sample.gpuPressureLevel
            ]
        )
    }

    private func invalidateChangedLiveRegions(
        from previous: LivePresentation,
        to current: LivePresentation
    ) {
        let layout = currentLayout()
        let cpu = layout.rect(for: .cpu) ?? .zero
        let memory = layout.rect(for: .memory) ?? .zero
        let gpu = layout.rect(for: .gpu) ?? .zero
        let thermal = layout.rect(for: .thermal) ?? .zero
        let gpuMemory = layout.rect(for: .gpuMemory) ?? .zero
        let disk = layout.rect(for: .disk) ?? .zero
        let network = layout.rect(for: .network) ?? .zero
        let info = layout.rect(for: .info) ?? .zero
        let extras = layout.rect(for: .extras) ?? .zero

        if previous.header != current.header || previous.headerDuration != current.headerDuration {
            invalidateVisible(NSRect(x: bounds.width * 0.5, y: 8, width: bounds.width * 0.5, height: 56))
        }
        if previous.cpu != current.cpu { invalidateVisible(liveMetricRect(for: cpu)) }
        if previous.memory != current.memory { invalidateVisible(liveMetricRect(for: memory)) }
        if previous.gpu != current.gpu { invalidateVisible(liveMetricRect(for: gpu)) }
        if previous.thermal != current.thermal { invalidateVisible(liveMetricRect(for: thermal)) }
        if previous.gpuMemory != current.gpuMemory { invalidateVisible(liveMetricRect(for: gpuMemory)) }
        if previous.disk != current.disk { invalidateVisible(liveMetricRect(for: disk)) }
        if previous.network != current.network {
            invalidateVisible(NSRect(x: network.minX + 2, y: network.minY + 5, width: network.width - 4, height: 54))
        }
        if previous.info != current.info {
            invalidateVisible(info.insetBy(dx: 2, dy: 5))
        }
        if previous.extras != current.extras {
            invalidateVisible(extras.insetBy(dx: 2, dy: 5))
        }
        if previous.ownProcess != current.ownProcess {
            // Asymmetric by design: the strip's text starts further in on the
            // leading edge than it stops from the trailing one.
            invalidateVisible(NSRect(
                x: layout.selfRect.minX + 7,
                y: layout.selfRect.minY + 6,
                width: layout.selfRect.width - 9,
                height: 31
            ))
        }

        let cards = [cpu, memory, gpu, thermal, gpuMemory]
        for index in cards.indices where previous.pressures[index] != current.pressures[index] {
            invalidateVisible(graphRect(for: cards[index]))
        }
    }

    private func invalidateTrendRegions() {
        let layout = currentLayout()
        for slot in layout.slots where !slot.section.isFullWidth {
            invalidateVisible(graphRect(for: slot.rect))
        }
        if let network = layout.rect(for: .network) {
            invalidateVisible(networkGraphRect(for: network))
        }
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

    private func makeUnitRegions(
        memoryRect: NSRect,
        thermalRect: NSRect,
        gpuMemoryRect: NSRect,
        diskRect: NSRect,
        networkRect: NSRect,
        extrasRect: NSRect,
        selfRect: NSRect,
        sample: SystemSample
    ) -> [UnitRegion] {
        let extrasWidth = extrasRect.width - 4
        let diskRect = NSRect(
            x: extrasRect.minX + 2,
            y: extrasRect.minY + 28,
            width: extrasWidth,
            height: 26
        )
        let byteRowRect = NSRect(
            x: extrasRect.minX + 2,
            y: extrasRect.minY + 55,
            width: extrasWidth,
            height: 26
        )
        let swapIORect = NSRect(
            x: extrasRect.minX + 2,
            y: extrasRect.minY + 82,
            width: extrasWidth,
            height: 26
        )
        let compressionRowRect = NSRect(
            x: extrasRect.minX + 2,
            y: extrasRect.minY + 109,
            width: extrasWidth,
            height: 26
        )
        let selfPrefix = "SEAROOM · CPU \(MetricFormat.unboundedPercent(sample.processCPUUsage)) · "
        let processMemoryValue = MetricFormat.compactBytes(
            sample.processMemoryBytes,
            unit: model.dashboardUnitState.byteUnit(for: .processMemory)
        )
        let processMemory = "RAM \(processMemoryValue)"
        let selfSummary = selfPrefix + processMemory
            + " · SAMPLE \(String(format: "%.0f", model.settings.sampleInterval))S"
        let selfAvailableWidth = selfRect.width - 28
        let selfFont = fittedMetricFont(
            selfSummary,
            maximumSize: 10.5,
            minimumSize: 8.5,
            width: selfAvailableWidth
        )
        let processMemoryX = selfRect.minX + 14 + textSize(selfPrefix, font: selfFont).width
        let processMemoryMaxX = selfRect.maxX - 14
        let processMemoryRect = NSRect(
            x: min(processMemoryX, processMemoryMaxX),
            y: selfRect.minY + 7,
            width: max(
                0,
                min(textSize(processMemory, font: selfFont).width, processMemoryMaxX - processMemoryX)
            ),
            height: 28
        )
        return [
            UnitRegion(
                target: .memory,
                hitRect: memoryRect,
                displayRect: liveMetricRect(for: memoryRect)
            ),
            UnitRegion(
                target: .temperature,
                hitRect: thermalRect,
                displayRect: liveMetricRect(for: thermalRect)
            ),
            UnitRegion(
                target: .gpuMemory,
                hitRect: gpuMemoryRect,
                displayRect: liveMetricRect(for: gpuMemoryRect)
            ),
            UnitRegion(
                target: .diskCapacity,
                hitRect: diskRect,
                displayRect: liveMetricRect(for: diskRect)
            ),
            UnitRegion(
                target: .network,
                hitRect: networkRect,
                displayRect: NSRect(
                    x: networkRect.minX + 2,
                    y: networkRect.minY + 5,
                    width: networkRect.width - 4,
                    height: 54
                )
            ),
            UnitRegion(target: .diskIO, hitRect: diskRect, displayRect: diskRect),
            UnitRegion(
                target: .cache,
                hitRect: NSRect(
                    x: byteRowRect.minX,
                    y: byteRowRect.minY,
                    width: byteRowRect.width / 2,
                    height: byteRowRect.height
                ),
                displayRect: NSRect(
                    x: byteRowRect.minX,
                    y: byteRowRect.minY,
                    width: byteRowRect.width / 2,
                    height: byteRowRect.height
                )
            ),
            UnitRegion(
                target: .swap,
                hitRect: NSRect(
                    x: byteRowRect.midX,
                    y: byteRowRect.minY,
                    width: byteRowRect.width / 2,
                    height: byteRowRect.height
                ),
                displayRect: NSRect(
                    x: byteRowRect.midX,
                    y: byteRowRect.minY,
                    width: byteRowRect.width / 2,
                    height: byteRowRect.height
                )
            ),
            UnitRegion(target: .swapIO, hitRect: swapIORect, displayRect: swapIORect),
            UnitRegion(
                target: .compressedMemory,
                hitRect: NSRect(
                    x: compressionRowRect.minX,
                    y: compressionRowRect.minY,
                    width: compressionRowRect.width / 2,
                    height: compressionRowRect.height
                ),
                displayRect: NSRect(
                    x: compressionRowRect.minX,
                    y: compressionRowRect.minY,
                    width: compressionRowRect.width / 2,
                    height: compressionRowRect.height
                )
            ),
            UnitRegion(
                target: .compression,
                hitRect: NSRect(
                    x: compressionRowRect.midX,
                    y: compressionRowRect.minY,
                    width: compressionRowRect.width / 2,
                    height: compressionRowRect.height
                ),
                displayRect: NSRect(
                    x: compressionRowRect.midX,
                    y: compressionRowRect.minY,
                    width: compressionRowRect.width / 2,
                    height: compressionRowRect.height
                )
            ),
            UnitRegion(
                target: .processMemory,
                hitRect: processMemoryRect,
                displayRect: selfRect
            )
        ]
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
        var gpuMemory: [Double] = []
        var diskUsed: [Double] = []
        var compressed: [Double] = []
        var download: [Double] = []
        var upload: [Double] = []
        let count = model.history.count
        for arrayIndex in 0..<count {
            let sample = model.history[arrayIndex]
            cpu.append(sample.cpuUsage)
            memory.append(Double(sample.memoryUsed) / Double(max(1, sample.memoryTotal)))
            if let value = sample.gpuUsage { gpu.append(value) }
            if let value = sample.temperatureCelsius { thermal.append(value) }
            if let value = sample.gpuMemoryPressure { gpuMemory.append(value) }
            if let capacity = sample.diskCapacityBytes, capacity > 0, let available = sample.diskAvailableBytes {
                diskUsed.append(min(1, max(0, 1 - Double(available) / Double(capacity))))
            }
            compressed.append(
                Double(sample.compressedMemoryBytes) / Double(max(1, sample.memoryTotal))
            )
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
            gpuMemory: normalize(downsample(gpuMemory, limit: cardLimit), scale: .percentage),
            diskUsed: normalize(downsample(diskUsed, limit: cardLimit), scale: .percentage),
            compressed: normalize(downsample(compressed, limit: cardLimit), scale: .percentage),
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
        let memory = MetricFormat.bytes(
            sample.memoryUsed,
            unit: model.dashboardUnitState.byteUnit(for: .memory)
        )
        let temperature = MetricFormat.temperature(
            sample.temperatureCelsius,
            unit: model.dashboardUnitState.temperatureUnit(for: .temperature)
        )
        let gpuMemoryUnit = model.dashboardUnitState.byteUnit(for: .gpuMemory)
        let gpuMemory = if let used = sample.gpuMemoryUsedBytes, let recommended = sample.gpuMemoryRecommendedBytes {
            "\(MetricFormat.bytes(used, unit: gpuMemoryUnit)) of \(MetricFormat.bytes(recommended, unit: gpuMemoryUnit))"
        } else {
            "an unavailable reading"
        }
        let diskCapacityUnit = model.dashboardUnitState.byteUnit(for: .diskCapacity)
        let diskAvailable = sample.diskAvailableBytes.map {
            "\(MetricFormat.bytes($0, unit: diskCapacityUnit)) free"
        } ?? "an unavailable reading"
        let processMemoryUnit = model.dashboardUnitState.byteUnit(for: .processMemory)
        let processMemory = MetricFormat.bytes(sample.processMemoryBytes, unit: processMemoryUnit)
        let sustained = SustainedPressure.duration(in: model.history)
        let sustainedPhrase = if let sustained, sustained.duration >= 60 {
            ", sustained for \(Self.spokenDuration(sustained.duration))"
        } else {
            ""
        }
        let selfImpact = "Searoom uses \(MetricFormat.unboundedPercent(sample.processCPUUsage)) CPU and "
            + "\(processMemory) memory. "
            + "Click a unit-bearing metric to change its display unit."
        setAccessibilityValue(
            "System \(sample.overallPressureLevel.systemLabel)\(sustainedPhrase). "
                + "CPU \(MetricFormat.percent(sample.cpuUsage)). "
                + "Memory \(memory) used. "
                + "GPU memory \(gpuMemory). "
                + "Disk \(diskAvailable). "
                + "Temperature \(temperature). "
                + selfImpact
        )
    }

    private static func spokenDuration(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        let minutes = seconds / 60
        let hours = minutes / 60
        let days = hours / 24
        if days > 0 { return "\(days) day\(days == 1 ? "" : "s")" }
        if hours > 0 { return "\(hours) hour\(hours == 1 ? "" : "s") \(minutes % 60) minutes" }
        return "\(minutes) minute\(minutes == 1 ? "" : "s")"
    }

    private func drawText(_ text: String, at point: NSPoint, font: NSFont, color: NSColor) {
        (text as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
    }

    private func drawText(
        _ text: String,
        in rect: NSRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .left
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = alignment
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

    private func fittedMetricFont(
        _ text: String,
        maximumSize: CGFloat,
        minimumSize: CGFloat,
        width: CGFloat
    ) -> NSFont {
        let font = SearoomFont.metric(maximumSize)
        let measuredWidth = textSize(text, font: font).width
        guard measuredWidth > width, measuredWidth > 0 else { return font }
        let fittedSize = floor(maximumSize * (width - 1) / measuredWidth * 10) / 10
        return SearoomFont.metric(max(minimumSize, fittedSize))
    }

    private enum GraphScale {
        case percentage
        case temperature
    }

    /// A press that has not yet moved far enough to be a drag.
    private struct DragCandidate {
        let section: DashboardSection
        let origin: NSPoint
        let rect: NSRect
    }

    private struct ActiveDrag {
        let section: DashboardSection
        let rect: NSRect
        /// Where in the card the pointer grabbed it, so the ghost does not jump.
        let grabOffset: NSPoint
        var point: NSPoint
        var insertionIndex: Int
    }

    private struct GraphRegion {
        let metric: DashboardTrendMetric
        let rect: NSRect
    }

    private struct UnitRegion {
        let target: DashboardUnitTarget
        let hitRect: NSRect
        let displayRect: NSRect
    }

    private struct HoverState: Equatable {
        let metric: DashboardTrendMetric
        let sampleTimestamp: Date
    }

    private struct LivePresentation: Equatable {
        let header: PressureLevel
        let headerDuration: String
        let cpu: String
        let memory: String
        let gpu: String
        let gpuMemory: String
        let disk: String
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
        let gpuMemory: [Double]
        let diskUsed: [Double]
        let compressed: [Double]
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

        let maximumFont = SearoomFont.metric(8.5)
        let maximumLabelSize = (label as NSString).size(withAttributes: [.font: maximumFont])
        let availableTextWidth = max(1, bounds.width - 10)
        let fittedSize = max(7, min(8.5, floor(8.5 * availableTextWidth / max(1, maximumLabelSize.width) * 10) / 10))
        let font = SearoomFont.metric(fittedSize)
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
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        (label as NSString).draw(
            with: NSRect(x: tooltip.minX + 5, y: tooltip.minY + 3, width: tooltip.width - 10, height: 13),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [
                .font: font,
                .foregroundColor: theme.ink,
                .paragraphStyle: paragraph
            ]
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
