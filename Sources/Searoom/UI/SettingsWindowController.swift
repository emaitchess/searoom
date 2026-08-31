import AppKit
import ServiceManagement

@MainActor
final class SettingsWindowController: NSWindowController {
    private let model: AppModel
    private let shortcutManager: GlobalShortcutManager
    private let presetPopUp = NSPopUpButton()
    private let customMetricPopUps = [NSPopUpButton(), NSPopUpButton(), NSPopUpButton()]
    private let intervalPopUp = NSPopUpButton()
    private let historyPopUp = NSPopUpButton()
    private let shortcutRecorder = ShortcutRecorderControl()
    private let shortcutClearButton = NSButton(title: "Clear", target: nil, action: nil)
    private let shortcutError = NSTextField(labelWithString: "")
    private let launchButton = NSButton(checkboxWithTitle: "Launch Searoom at login", target: nil, action: nil)
    private let resetHistoryButton = NSButton(title: "Reset Trend History", target: nil, action: nil)
    private let updatesButton = NSButton(title: "Check for Updates", target: nil, action: nil)
    private let emaitchessButton = NSButton(title: "PART OF EMAITCHESS ↗", target: nil, action: nil)

    init(model: AppModel, shortcutManager: GlobalShortcutManager) {
        self.model = model
        self.shortcutManager = shortcutManager
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Searoom Settings"
        window.isReleasedWhenClosed = true
        window.center()
        super.init(window: window)
        configureContent()
        syncFromModel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        syncFromModel()
        showWindow(nil)
        window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func configureContent() {
        guard let window else { return }
        let root = SettingsBackgroundView()
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root

        let title = makeLabel("SEAROOM / SETTINGS", size: 18, color: .labelColor)
        let subtitle = makeLabel("QUIET TELEMETRY FOR MACHINES UNDER LOAD", size: 8, color: .secondaryLabelColor)
        let heading = NSStackView(views: [title, subtitle])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 6
        heading.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(heading)

        presetPopUp.addItems(withTitles: MenuBarPreset.allCases.map(\.title))
        for (index, popUp) in customMetricPopUps.enumerated() {
            popUp.addItem(withTitle: "None")
            popUp.addItems(withTitles: MenuBarMetric.allCases.map(\.title))
            popUp.target = self
            popUp.action = #selector(customMetricChanged)
            popUp.controlSize = .small
            popUp.font = SearoomFont.system(11)
            popUp.setAccessibilityLabel("Custom menu-bar metric \(index + 1)")
        }
        let customMetricControls = NSStackView(views: customMetricPopUps)
        customMetricControls.orientation = .horizontal
        customMetricControls.alignment = .centerY
        customMetricControls.distribution = .fillEqually
        customMetricControls.spacing = 6
        customMetricControls.toolTip = "Choose Custom above, then select up to three menu-bar metrics."
        intervalPopUp.addItems(withTitles: ["1 second", "2 seconds", "5 seconds", "10 seconds"])
        historyPopUp.addItems(withTitles: ["15 minutes", "30 minutes", "1 hour", "3 hours"])
        shortcutRecorder.onChange = { [weak self] shortcut in
            self?.changeShortcut(shortcut) ?? false
        }
        shortcutClearButton.bezelStyle = .rounded
        shortcutClearButton.controlSize = .small
        shortcutClearButton.target = self
        shortcutClearButton.action = #selector(clearShortcut)
        shortcutClearButton.setAccessibilityLabel("Clear global shortcut")
        shortcutRecorder.controlSize = .small
        shortcutClearButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        shortcutRecorder.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let shortcutControls = NSStackView(views: [shortcutRecorder, shortcutClearButton])
        shortcutControls.orientation = .horizontal
        shortcutControls.alignment = .centerY
        shortcutControls.distribution = .fillEqually
        shortcutControls.spacing = 8
        shortcutClearButton.heightAnchor.constraint(equalTo: shortcutRecorder.heightAnchor).isActive = true
        shortcutError.font = SearoomFont.system(10)
        shortcutError.textColor = .systemRed
        let shortcutGroup = NSStackView(views: [shortcutControls, shortcutError])
        shortcutGroup.orientation = .vertical
        shortcutGroup.alignment = .width
        shortcutGroup.spacing = 3

        presetPopUp.target = self
        presetPopUp.action = #selector(presetChanged)
        intervalPopUp.target = self
        intervalPopUp.action = #selector(intervalChanged)
        historyPopUp.target = self
        historyPopUp.action = #selector(historyChanged)
        launchButton.target = self
        launchButton.action = #selector(launchChanged)
        resetHistoryButton.bezelStyle = .rounded
        resetHistoryButton.controlSize = .small
        resetHistoryButton.target = self
        resetHistoryButton.action = #selector(resetHistory)
        resetHistoryButton.setAccessibilityLabel("Reset saved trend history")
        updatesButton.bezelStyle = .rounded
        updatesButton.controlSize = .small
        updatesButton.target = self
        updatesButton.action = #selector(checkForUpdates)
        updatesButton.setAccessibilityLabel("Check for Searoom updates")
        updatesButton.setAccessibilityHelp(
            "Asks searoom.app which version is current. Nothing is downloaded or installed."
        )

        let grid = NSGridView(views: [
            [makeLabel("MENU BAR", size: 10, color: .secondaryLabelColor), presetPopUp],
            [makeLabel("CUSTOM METRICS", size: 10, color: .secondaryLabelColor), customMetricControls],
            [makeLabel("GLOBAL SHORTCUT", size: 10, color: .secondaryLabelColor), shortcutGroup],
            [makeLabel("SAMPLE RATE", size: 10, color: .secondaryLabelColor), intervalPopUp],
            [makeLabel("TREND WINDOW", size: 10, color: .secondaryLabelColor), historyPopUp]
        ])
        grid.rowSpacing = 14
        grid.columnSpacing = 24
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .fill
        grid.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(grid)

        let storageControls = NSStackView(views: [launchButton, updatesButton, resetHistoryButton])
        storageControls.orientation = .horizontal
        storageControls.alignment = .centerY
        storageControls.distribution = .equalSpacing
        storageControls.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(storageControls)

        let note = NSTextField(wrappingLabelWithString:
            "CPU pressure is a derived saturation signal. Temperature, fan and GPU readings are best-effort because macOS does not expose universal public APIs for them. Unsupported sensors remain clearly unavailable. All history stays in ~/Library/Application Support/Searoom."
        )
        note.font = SearoomFont.system(11)
        note.textColor = .secondaryLabelColor
        note.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(note)

        // The version belongs here rather than in a separate row: it is reference
        // information, not a control, and it replaces the "no network access"
        // claim that the user-initiated update check made untrue.
        let version = UpdateChecker.currentVersion
        let license = makeLabel(
            "SEAROOM \(version) · OPEN SOURCE · MIT · NO ANALYTICS",
            size: 8,
            color: .secondaryLabelColor
        )
        license.setAccessibilityLabel(
            "Searoom version \(version). Open source, MIT licensed, no analytics."
        )
        license.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(license)

        emaitchessButton.isBordered = false
        emaitchessButton.font = SearoomFont.metric(8)
        emaitchessButton.contentTintColor = .secondaryLabelColor
        emaitchessButton.alignment = .right
        emaitchessButton.target = self
        emaitchessButton.action = #selector(openEmaitchessWebsite)
        emaitchessButton.toolTip = "https://emaitchess.com/"
        emaitchessButton.setAccessibilityLabel("Part of emaitchess")
        emaitchessButton.setAccessibilityHelp("Opens the emaitchess website in your default browser")
        emaitchessButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(emaitchessButton)

        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            heading.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            grid.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 28),
            storageControls.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            storageControls.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            storageControls.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 20),
            note.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            note.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            note.topAnchor.constraint(equalTo: storageControls.bottomAnchor, constant: 20),
            license.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            license.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -19),
            emaitchessButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            emaitchessButton.firstBaselineAnchor.constraint(equalTo: license.firstBaselineAnchor),
            emaitchessButton.leadingAnchor.constraint(greaterThanOrEqualTo: license.trailingAnchor, constant: 12)
        ])
    }

    private func syncFromModel() {
        presetPopUp.selectItem(at: MenuBarPreset.allCases.firstIndex(of: model.settings.menuBarPreset) ?? 0)
        syncCustomMetricControls()
        let intervals = AppSettings.supportedSampleIntervals
        intervalPopUp.selectItem(at: intervals.firstIndex(of: model.settings.sampleInterval) ?? 1)
        let historyValues = AppSettings.supportedHistoryMinutes
        historyPopUp.selectItem(at: historyValues.firstIndex(of: model.settings.historyMinutes) ?? 1)
        shortcutRecorder.shortcut = model.settings.globalShortcut
        shortcutClearButton.isEnabled = model.settings.globalShortcut != nil
        launchButton.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func presetChanged() {
        let preset = MenuBarPreset.allCases[max(0, presetPopUp.indexOfSelectedItem)]
        model.updateSettings { $0.menuBarPreset = preset }
        syncCustomMetricControls()
    }

    @objc private func customMetricChanged() {
        let metrics = customMetricPopUps.compactMap { popUp -> MenuBarMetric? in
            let index = popUp.indexOfSelectedItem - 1
            guard MenuBarMetric.allCases.indices.contains(index) else { return nil }
            return MenuBarMetric.allCases[index]
        }
        model.updateSettings {
            $0.customMenuBarMetrics = MenuBarMetric.normalized(metrics)
            $0.menuBarPreset = .custom
        }
        presetPopUp.selectItem(at: MenuBarPreset.allCases.firstIndex(of: .custom) ?? 0)
        syncCustomMetricControls()
    }

    private func syncCustomMetricControls() {
        for (index, popUp) in customMetricPopUps.enumerated() {
            if model.settings.customMenuBarMetrics.indices.contains(index),
               let metricIndex = MenuBarMetric.allCases.firstIndex(
                of: model.settings.customMenuBarMetrics[index]
               ) {
                popUp.selectItem(at: metricIndex + 1)
            } else {
                popUp.selectItem(at: 0)
            }
            popUp.isEnabled = model.settings.menuBarPreset == .custom
        }
    }

    @objc private func intervalChanged() {
        let values = AppSettings.supportedSampleIntervals
        let value = values[max(0, intervalPopUp.indexOfSelectedItem)]
        model.updateSettings { $0.sampleInterval = value }
    }

    @objc private func historyChanged() {
        let values = AppSettings.supportedHistoryMinutes
        let value = values[max(0, historyPopUp.indexOfSelectedItem)]
        model.updateSettings { $0.historyMinutes = value }
    }

    @objc private func launchChanged() {
        do {
            if launchButton.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchButton.state = SMAppService.mainApp.status == .enabled ? .on : .off
            let alert = NSAlert()
            alert.messageText = "Could not update Login Items"
            alert.informativeText = error.localizedDescription
            if let window { alert.beginSheetModal(for: window) }
        }
    }

    /// Settings is where people look for this, so the check is reachable here as
    /// well as from the status-item menu. Both paths run only on activation.
    @objc private func checkForUpdates() {
        UpdateChecker.check { outcome in
            Task { @MainActor in UpdatePresenter.present(outcome) }
        }
    }

    @objc private func resetHistory() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Reset trend history?"
        alert.informativeText = "This permanently clears Searoom's saved trend samples. Your settings and shortcut will not change."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset History")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor in self?.model.resetHistory() }
        }
    }

    @objc private func openEmaitchessWebsite() {
        guard let url = URL(string:
            "https://emaitchess.com/?utm_source=searoom&utm_medium=desktop_app&utm_campaign=product_attribution&utm_content=settings_footer"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func clearShortcut() {
        guard model.settings.globalShortcut != nil else { return }
        if changeShortcut(nil) { shortcutRecorder.shortcut = nil }
    }

    private func changeShortcut(_ shortcut: GlobalShortcut?) -> Bool {
        let previous = model.settings.globalShortcut
        guard let shortcut else {
            shortcutManager.unregister()
            shortcutError.stringValue = ""
            model.updateSettings { $0.globalShortcut = nil }
            shortcutClearButton.isEnabled = false
            return true
        }

        let status = shortcutManager.register(shortcut)
        guard status == noErr else {
            if let previous { _ = shortcutManager.register(previous) }
            shortcutError.stringValue = "That shortcut is already in use."
            return false
        }
        shortcutError.stringValue = ""
        model.updateSettings { $0.globalShortcut = shortcut }
        shortcutClearButton.isEnabled = true
        return true
    }

    private func makeLabel(_ text: String, size: CGFloat, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = SearoomFont.metric(size)
        label.textColor = color
        return label
    }
}

@MainActor
private final class SettingsBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let theme = SearoomTheme(appearance: effectiveAppearance)
        theme.paper.setFill()
        bounds.fill()
        let header = NSBezierPath(rect: NSRect(x: 0, y: bounds.height - 84, width: bounds.width, height: 84))
        DitherPattern.fill(header, color: theme.ink.withAlphaComponent(0.12), density: 0.25)
    }
}
