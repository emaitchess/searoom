import AppKit
import ServiceManagement

private enum MenuBarTone: Equatable {
    case pressure(PressureLevel)
    case activity(Bool)
    case neutral
}

private struct MenuBarComponent: Equatable {
    let text: String
    let tone: MenuBarTone
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover?
    private var dashboardController: DashboardViewController?
    private var settingsController: SettingsWindowController?
    private var shortcutManager: GlobalShortcutManager!
    private var model: AppModel!
    private let metricsEngine = MetricsEngine()
    private var lastStatusComponents: [MenuBarComponent] = []
    private var lastStatusLevel = PressureLevel.unavailable
    private var lastStatusPreset: MenuBarPreset?
    private var lastStatusAppearance: NSAppearance.Name?
    private var lastAccessibilityValue = ""
    private var activeSampleInterval: TimeInterval?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        SearoomFont.registerBundledFont()

        model = AppModel()
        shortcutManager = GlobalShortcutManager { [weak self] in
            Task { @MainActor in self?.toggleDashboard() }
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imageHugsTitle = true
            let usesMinimalPreset = model.settings.menuBarPreset == .minimal
            button.imagePosition = usesMinimalPreset ? .imageOnly : .imageLeading
            button.image = usesMinimalPreset
                ? SearoomIcon.image(for: .unavailable)
                : SearoomStatusDot.image(for: .unavailable, appearance: button.effectiveAppearance)
            button.toolTip = "Searoom is collecting system telemetry"
        }
        configureApplicationMenu()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sampleUpdated),
            name: .searoomSampleUpdated,
            object: model
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsUpdated),
            name: .searoomSettingsUpdated,
            object: model
        )

        updateStatusItem()
        if let shortcut = model.settings.globalShortcut {
            _ = shortcutManager.register(shortcut)
        }
        startSampling()
        DispatchQueue.main.async { [weak self] in
            self?.presentLaunchAtLoginPromptIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        metricsEngine.stop()
        model?.flushHistory()
        NotificationCenter.default.removeObserver(self)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent, let button = statusItem.button else { return }
        if event.type == .rightMouseUp {
            NSMenu.popUpContextMenu(makeContextMenu(), with: event, for: button)
            return
        }
        toggleDashboard()
    }

    private func toggleDashboard() {
        guard let button = statusItem.button else { return }
        if popover?.isShown == true {
            popover?.performClose(nil)
        } else {
            let popover = makePopoverIfNeeded()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    @objc private func sampleUpdated() {
        updateStatusItem()
        if popover?.isShown == true {
            dashboardController?.dashboardView.refresh()
        }
    }

    @objc private func settingsUpdated() {
        if activeSampleInterval != model.settings.sampleInterval { startSampling() }
    }

    @objc private func openDashboard() {
        guard let button = statusItem.button else { return }
        let popover = makePopoverIfNeeded()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    @objc private func openSettings() {
        popover?.performClose(nil)
        showSettingsWindow()
    }

    @objc private func selectPreset(_ sender: NSMenuItem) {
        guard let preset = sender.representedObject as? String,
              let selected = MenuBarPreset(rawValue: preset) else { return }
        model.updateSettings { $0.menuBarPreset = selected }
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Searoom"
        alert.informativeText = "Quiet, local telemetry for Macs under load.\n\nOpen-source under the MIT License. Departure Mono by Helena Zhang is bundled under the SIL Open Font License."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func startSampling() {
        guard let model = self.model else { return }
        activeSampleInterval = model.settings.sampleInterval
        metricsEngine.start(interval: model.settings.sampleInterval) { sample in
            model.consume(sample)
        }
    }

    private func makePopoverIfNeeded() -> NSPopover {
        if let popover { return popover }

        let controller = DashboardViewController(model: model)
        controller.dashboardView.onOpenSettings = { [weak self] in
            self?.popover?.performClose(nil)
            self?.showSettingsWindow()
        }
        controller.dashboardView.onOpenActivityMonitor = { [weak self] in
            self?.popover?.performClose(nil)
            self?.openActivityMonitor()
        }
        controller.dashboardView.onQuit = { NSApp.terminate(nil) }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = controller
        popover.contentSize = controller.preferredContentSize
        dashboardController = controller
        self.popover = popover
        return popover
    }

    func popoverDidClose(_ notification: Notification) {
        dashboardController?.dashboardView.prepareForClose()
        popover?.contentViewController = nil
        dashboardController = nil
        popover = nil
    }

    private func showSettingsWindow() {
        if settingsController == nil {
            settingsController = SettingsWindowController(model: model, shortcutManager: shortcutManager)
            settingsController?.window?.delegate = self
        }
        settingsController?.show()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === settingsController?.window else { return }
        settingsController = nil
    }

    private func openActivityMonitor() {
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.ActivityMonitor"
        ), NSWorkspace.shared.open(url) else {
            let alert = NSAlert()
            alert.messageText = "Could not open Activity Monitor"
            alert.informativeText = "Searoom could not locate the system Activity Monitor application."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
    }

    private func presentLaunchAtLoginPromptIfNeeded() {
        let isPackaged = Bundle.main.bundleURL.pathExtension.caseInsensitiveCompare("app")
            == .orderedSame
        let serviceIsNotRegistered = SMAppService.mainApp.status == .notRegistered
        guard LaunchAtLoginPromptPolicy.shouldPrompt(
            isPackaged: isPackaged,
            hasCompleted: model.settings.hasCompletedLaunchAtLoginPrompt,
            serviceIsNotRegistered: serviceIsNotRegistered
        ) else {
            if isPackaged,
               !model.settings.hasCompletedLaunchAtLoginPrompt,
               !serviceIsNotRegistered {
                model.updateSettings { $0.hasCompletedLaunchAtLoginPrompt = true }
            }
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Open Searoom at Login?"
        alert.informativeText = "Searoom can start quietly in the menu bar whenever you log in. You can change this later in Settings."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open at Login")
        alert.addButton(withTitle: "Not Now")
        let response = alert.runModal()

        model.updateSettings { $0.hasCompletedLaunchAtLoginPrompt = true }
        guard response == .alertFirstButtonReturn else { return }

        do {
            try SMAppService.mainApp.register()
        } catch {
            let errorAlert = NSAlert()
            errorAlert.messageText = "Could Not Open Searoom at Login"
            errorAlert.informativeText = "\(error.localizedDescription)\n\nYou can try again from Settings."
            errorAlert.alertStyle = .warning
            errorAlert.addButton(withTitle: "OK")
            errorAlert.runModal()
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let sample = model.currentSample
        let preset = model.settings.menuBarPreset
        let components = menuBarComponents(sample: sample, preset: preset)
        let text = components.map(\.text).joined(separator: "·")
        let level = sample.overallPressureLevel
        let appearance = button.effectiveAppearance
            .bestMatch(from: [.darkAqua, .aqua]) ?? .aqua
        let appearanceChanged = appearance != lastStatusAppearance
        let presentationChanged = level != lastStatusLevel
            || preset != lastStatusPreset
            || appearanceChanged

        let desiredLength = preset == .minimal
            ? NSStatusItem.squareLength
            : NSStatusItem.variableLength
        if statusItem.length != desiredLength { statusItem.length = desiredLength }
        button.alignment = preset == .minimal ? .center : .left

        if preset == .minimal {
            button.imagePosition = .imageOnly
            if presentationChanged || button.image == nil {
                button.image = SearoomIcon.image(for: level)
            }
        } else {
            button.imagePosition = .imageLeading
            if presentationChanged || button.image == nil {
                button.image = SearoomStatusDot.image(
                    for: level,
                    appearance: button.effectiveAppearance
                )
            }
        }
        if components != lastStatusComponents || appearanceChanged {
            button.attributedTitle = attributedMenuBarTitle(
                components,
                appearance: button.effectiveAppearance
            )
            lastStatusComponents = components
        }
        lastStatusLevel = level
        lastStatusPreset = preset
        lastStatusAppearance = appearance
        let accessibilityValue = accessibilityDescription(for: sample, statusText: text)
        if accessibilityValue != lastAccessibilityValue {
            button.toolTip = accessibilityValue
            button.setAccessibilityLabel("Searoom")
            button.setAccessibilityValue(accessibilityValue)
            lastAccessibilityValue = accessibilityValue
        }
    }

    private func menuBarComponents(
        sample: SystemSample,
        preset: MenuBarPreset
    ) -> [MenuBarComponent] {
        switch preset {
        case .balanced:
            [
                component(
                    "CPU \(menuPercent(sample.cpuUsage))",
                    pressure: usageLevel(sample.cpuUsage)
                ),
                component("RAM \(menuBytes(sample.memoryUsed))", pressure: sample.memoryPressureLevel)
            ]
        case .reserve:
            [
                component("FREE \(menuBytes(sample.memoryAvailable))", pressure: sample.memoryPressureLevel),
                component("SWAP \(menuBytes(sample.swapUsed))", pressure: sample.memoryPressureLevel)
            ]
        case .pressure:
            [
                component("MEM \(menuPressure(sample.memoryPressureLevel))", pressure: sample.memoryPressureLevel),
                component("THERM \(menuPressure(sample.thermalPressureLevel))", pressure: sample.thermalPressureLevel)
            ]
        case .llm:
            [
                component(
                    "RAM \(menuBytes(sample.memoryUsed))/\(menuBytes(sample.memoryTotal))",
                    pressure: sample.memoryPressureLevel
                ),
                component(compactTemperature(sample), pressure: sample.thermalPressureLevel)
            ]
        case .compute:
            [
                component(
                    "CPU \(menuPercent(sample.cpuUsage))",
                    pressure: usageLevel(sample.cpuUsage)
                ),
                component("GPU \(menuPercent(sample.gpuUsage))", pressure: sample.gpuPressureLevel)
            ]
        case .network:
            [
                activityComponent("↓\(menuRate(sample.networkDownloadPerSecond))", value: sample.networkDownloadPerSecond),
                activityComponent("↑\(menuRate(sample.networkUploadPerSecond))", value: sample.networkUploadPerSecond)
            ]
        case .disk:
            [
                activityComponent("R \(menuRate(sample.diskReadPerSecond))", value: sample.diskReadPerSecond),
                activityComponent("W \(menuRate(sample.diskWritePerSecond))", value: sample.diskWritePerSecond)
            ]
        case .swap:
            [
                component("IN \(menuRate(sample.swapInPerSecond))", pressure: swapLevel(sample.swapInPerSecond, sample: sample)),
                component("OUT \(menuRate(sample.swapOutPerSecond))", pressure: swapLevel(sample.swapOutPerSecond, sample: sample))
            ]
        case .thermal:
            [
                component(compactTemperature(sample), pressure: sample.thermalPressureLevel),
                component("FAN \(menuFan(sample))", pressure: fanLevel(sample))
            ]
        case .power:
            powerComponents(sample)
        case .custom:
            model.settings.customMenuBarMetrics
                .flatMap { customMetricComponents($0, sample: sample) }
        case .minimal:
            []
        }
    }

    private func attributedMenuBarTitle(
        _ components: [MenuBarComponent],
        appearance: NSAppearance?
    ) -> NSAttributedString {
        let title = NSMutableAttributedString()
        let theme = SearoomTheme(appearance: appearance)
        for (index, component) in components.enumerated() {
            if index > 0 {
                title.append(NSAttributedString(
                    string: "·",
                    attributes: [
                        .font: SearoomFont.metric(9.5),
                        .foregroundColor: theme.subdued
                    ]
                ))
            }
            let color: NSColor = switch component.tone {
            case .pressure(let level): theme.color(for: level)
            case .activity(true): theme.cool
            case .activity(false): theme.subdued
            case .neutral: .labelColor
            }
            title.append(NSAttributedString(
                string: component.text,
                attributes: [
                    .font: SearoomFont.metric(10.5),
                    .foregroundColor: color
                ]
            ))
        }
        return title
    }

    private func compactTemperature(_ sample: SystemSample) -> String {
        let source = MetricFormat.fixedLabel(sample.temperatureSource.compactLabel, columns: 4)
        let value = MetricFormat.fixedField(
            MetricFormat.temperature(sample.temperatureCelsius),
            columns: 5
        )
        return "\(source) \(value)"
    }

    private func powerComponents(_ sample: SystemSample) -> [MenuBarComponent] {
        let source: String = switch (sample.isOnExternalPower, sample.batteryPercent) {
        case (true, _): "AC"
        case (false, let percent?): "BAT \(MetricFormat.percent(percent))"
        case (nil, let percent?): "BAT \(MetricFormat.percent(percent))"
        default: "N/A"
        }
        let sourceField = MetricFormat.fixedField(source, columns: 8)
        let mode = MetricFormat.fixedField(sample.isLowPowerModeEnabled ? "ON" : "OFF", columns: 3)
        return [
            component("PWR \(sourceField)", pressure: powerLevel(sample)),
            MenuBarComponent(text: "LPM \(mode)", tone: .activity(sample.isLowPowerModeEnabled))
        ]
    }

    private func customMetricComponents(
        _ metric: MenuBarMetric,
        sample: SystemSample
    ) -> [MenuBarComponent] {
        switch metric {
        case .cpuUsage:
            [component("CPU \(menuPercent(sample.cpuUsage))", pressure: usageLevel(sample.cpuUsage))]
        case .cpuPressure:
            [component("CPU-P \(menuPressure(sample.cpuPressureLevel))", pressure: sample.cpuPressureLevel)]
        case .memoryUsed:
            [component("RAM \(menuBytes(sample.memoryUsed))", pressure: sample.memoryPressureLevel)]
        case .memoryFree:
            [component("FREE \(menuBytes(sample.memoryAvailable))", pressure: sample.memoryPressureLevel)]
        case .memoryFreeUsed:
            [component(
                "FREE \(menuBytes(sample.memoryAvailable))/USED \(menuBytes(sample.memoryUsed))",
                pressure: sample.memoryPressureLevel
            )]
        case .memoryPressure:
            [component("MEM-P \(menuPressure(sample.memoryPressureLevel))", pressure: sample.memoryPressureLevel)]
        case .swapUsed:
            [component("SWAP \(menuBytes(sample.swapUsed))", pressure: sample.memoryPressureLevel)]
        case .swapIn:
            [component(
                "S-IN \(menuRate(sample.swapInPerSecond))",
                pressure: swapLevel(sample.swapInPerSecond, sample: sample)
            )]
        case .swapOut:
            [component(
                "S-OUT \(menuRate(sample.swapOutPerSecond))",
                pressure: swapLevel(sample.swapOutPerSecond, sample: sample)
            )]
        case .temperature:
            [component(compactTemperature(sample), pressure: sample.thermalPressureLevel)]
        case .thermalPressure:
            [component("THERM \(menuPressure(sample.thermalPressureLevel))", pressure: sample.thermalPressureLevel)]
        case .gpuUsage:
            [component("GPU \(menuPercent(sample.gpuUsage))", pressure: sample.gpuPressureLevel)]
        case .gpuPressure:
            [component("GPU-P \(menuPressure(sample.gpuPressureLevel))", pressure: sample.gpuPressureLevel)]
        case .networkDownload:
            [activityComponent("↓\(menuRate(sample.networkDownloadPerSecond))", value: sample.networkDownloadPerSecond)]
        case .networkUpload:
            [activityComponent("↑\(menuRate(sample.networkUploadPerSecond))", value: sample.networkUploadPerSecond)]
        case .diskRead:
            [activityComponent("R \(menuRate(sample.diskReadPerSecond))", value: sample.diskReadPerSecond)]
        case .diskWrite:
            [activityComponent("W \(menuRate(sample.diskWritePerSecond))", value: sample.diskWritePerSecond)]
        case .fan:
            [component("FAN \(menuFan(sample))", pressure: fanLevel(sample))]
        case .power:
            powerComponents(sample)
        case .uptime:
            [MenuBarComponent(
                text: "UP \(MetricFormat.fixedField(MetricFormat.uptime(sample.uptime), columns: 9))",
                tone: .neutral
            )]
        case .processCPU:
            [component(
                "SR-CPU \(MetricFormat.fixedField(MetricFormat.unboundedPercent(sample.processCPUUsage), columns: 5))",
                pressure: usageLevel(sample.processCPUUsage)
            )]
        case .processMemory:
            [component("SR-RAM \(menuBytes(sample.processMemoryBytes))", pressure: sample.memoryPressureLevel)]
        }
    }

    private func component(_ text: String, pressure: PressureLevel) -> MenuBarComponent {
        MenuBarComponent(text: text, tone: .pressure(pressure))
    }

    private func activityComponent(_ text: String, value: Double) -> MenuBarComponent {
        MenuBarComponent(text: text, tone: .activity(value >= 1))
    }

    private func usageLevel(_ value: Double?) -> PressureLevel {
        value.map(PressureLevel.from(utilization:)) ?? .unavailable
    }

    private func fanLevel(_ sample: SystemSample) -> PressureLevel {
        sample.fans.isEmpty ? .unavailable : sample.thermalPressureLevel
    }

    private func swapLevel(_ rate: Double, sample: SystemSample) -> PressureLevel {
        let activityLevel: PressureLevel = rate >= 1 ? .elevated : .nominal
        return max(activityLevel, sample.memoryPressureLevel)
    }

    private func powerLevel(_ sample: SystemSample) -> PressureLevel {
        if sample.isOnExternalPower == true { return .nominal }
        guard let percent = sample.batteryPercent else { return .unavailable }
        return switch percent {
        case ..<0.10: .critical
        case ..<0.20: .constrained
        case ..<0.40: .elevated
        default: .nominal
        }
    }

    private func menuPercent(_ value: Double?) -> String {
        MetricFormat.fixedField(value.map(MetricFormat.percent) ?? "N/A", columns: 4)
    }

    private func menuBytes(_ value: UInt64) -> String {
        MetricFormat.fixedField(MetricFormat.compactBytes(value), columns: 5)
    }

    private func menuRate(_ value: Double) -> String {
        MetricFormat.fixedField(MetricFormat.compactRate(value), columns: 7)
    }

    private func menuPressure(_ level: PressureLevel) -> String {
        MetricFormat.fixedField(level.compactLabel, columns: 5)
    }

    private func menuFan(_ sample: SystemSample) -> String {
        let fan = sample.fans.first.map { "\(Int($0.rpm))" } ?? "N/A"
        return MetricFormat.fixedField(fan, columns: 5)
    }

    private func accessibilityDescription(for sample: SystemSample, statusText: String) -> String {
        let visibleMetrics = statusText.isEmpty
            ? "icon only"
            : statusText
                .replacingOccurrences(of: "·", with: ", ")
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
        return "System \(sample.overallPressureLevel.systemLabel), menu bar \(visibleMetrics), CPU \(MetricFormat.percent(sample.cpuUsage)), memory \(MetricFormat.bytes(sample.memoryUsed)) used, temperature \(MetricFormat.temperature(sample.temperatureCelsius))"
    }

    /// The only network request Searoom makes, and only from this menu item.
    /// Nothing is downloaded or installed: a newer version opens the release
    /// page in the browser and the user decides what to do.
    @objc private func checkForUpdates() {
        UpdateChecker.check { outcome in
            Task { @MainActor in UpdatePresenter.present(outcome) }
        }
    }

    private func configureApplicationMenu() {
        let mainMenu = NSMenu(title: "Searoom")
        let applicationItem = NSMenuItem(title: "Searoom", action: nil, keyEquivalent: "")
        let applicationMenu = NSMenu(title: "Searoom")

        let aboutItem = NSMenuItem(
            title: "About Searoom",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        applicationMenu.addItem(aboutItem)

        let updatesItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        updatesItem.target = self
        applicationMenu.addItem(updatesItem)

        let settingsItem = NSMenuItem(
            title: "Settings",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        applicationMenu.addItem(settingsItem)
        applicationMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Searoom",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        applicationMenu.addItem(quitItem)

        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)
        NSApp.mainMenu = mainMenu
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Searoom")

        let openItem = NSMenuItem(title: "Open Searoom", action: #selector(openDashboard), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let presetsItem = NSMenuItem(title: "Menu Bar", action: nil, keyEquivalent: "")
        let presetsMenu = NSMenu(title: "Menu Bar")
        for preset in MenuBarPreset.allCases {
            let item = NSMenuItem(title: preset.title, action: #selector(selectPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.rawValue
            item.state = preset == model.settings.menuBarPreset ? .on : .off
            presetsMenu.addItem(item)
        }
        presetsItem.submenu = presetsMenu
        menu.addItem(presetsItem)

        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let aboutItem = NSMenuItem(title: "About Searoom", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        let updatesItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        updatesItem.target = self
        menu.addItem(updatesItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Searoom", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)
        return menu
    }
}

@MainActor
enum UpdatePresenter {
    static func present(_ outcome: UpdateCheckOutcome) {
        let alert = NSAlert()
        NSApp.activate(ignoringOtherApps: true)

        switch outcome {
        case .upToDate(let current):
            alert.messageText = "Searoom is up to date."
            alert.informativeText = "You are running version \(current)."
            alert.addButton(withTitle: "OK")
            alert.runModal()

        case .updateAvailable(let version, let url):
            alert.messageText = "Searoom \(version) is available."
            alert.informativeText = "You are running \(UpdateChecker.currentVersion). "
                + "Searoom does not install updates itself, so the release page "
                + "will open in your browser."
            alert.addButton(withTitle: "Open Release Page")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(url)
            }

        case .failed(let reason):
            alert.alertStyle = .warning
            alert.messageText = "Could not check for updates."
            alert.informativeText = reason
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}

enum LaunchAtLoginPromptPolicy {
    static func shouldPrompt(
        isPackaged: Bool,
        hasCompleted: Bool,
        serviceIsNotRegistered: Bool
    ) -> Bool {
        isPackaged && !hasCompleted && serviceIsNotRegistered
    }
}
