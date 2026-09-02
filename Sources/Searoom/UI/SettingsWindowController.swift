import AppKit
import ServiceManagement

@MainActor
final class SettingsWindowController: NSWindowController, NSTextViewDelegate,
    NSTableViewDataSource, NSTableViewDelegate {
    private let model: AppModel
    private let shortcutManager: GlobalShortcutManager
    private let metricTable = NSTableView()
    private let metricScroll = NSScrollView()
    private let addMetricPopUp = NSPopUpButton()
    private let moveMetricUpButton = NSButton(title: "Move Up", target: nil, action: nil)
    private let moveMetricDownButton = NSButton(title: "Move Down", target: nil, action: nil)
    private let removeMetricButton = NSButton(title: "Remove", target: nil, action: nil)
    private let metricPreview = NSTextField(labelWithString: "")
    private let layoutControl = NSSegmentedControl(
        labels: MenuBarLayout.allCases.map(\.title),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private var menuBarMetrics: [MenuBarMetric] = MenuBarMetric.defaults
    private let intervalPopUp = NSPopUpButton()
    private let historyPopUp = NSPopUpButton()
    private let shortcutRecorder = ShortcutRecorderControl()
    private let shortcutClearButton = NSButton(title: "Clear", target: nil, action: nil)
    private let shortcutError = NSTextField(labelWithString: "")
    private let launchButton = NSButton(checkboxWithTitle: "Launch Searoom at login", target: nil, action: nil)
    private let resetHistoryButton = NSButton(title: "Reset Trend History", target: nil, action: nil)
    private let updatesButton = NSButton(title: "Check for Updates", target: nil, action: nil)
    private let githubButton = NSButton(title: "GITHUB ↗", target: nil, action: nil)
    private let emaitchessButton = NSButton(title: "PART OF EMAITCHESS ↗", target: nil, action: nil)
    private let orderTable = NSTableView()
    private let orderScroll = NSScrollView()
    private let moveUpButton = NSButton(title: "Move Up", target: nil, action: nil)
    private let moveDownButton = NSButton(title: "Move Down", target: nil, action: nil)
    private let resetOrderButton = NSButton(title: "Default Order", target: nil, action: nil)
    /// Mirrors the persisted order so the table has a stable data source; the
    /// dashboard can also change it by drag, so `show()` re-reads the model.
    private var sectionOrder: [DashboardSection] = DashboardSection.defaults

    init(model: AppModel, shortcutManager: GlobalShortcutManager) {
        self.model = model
        self.shortcutManager = shortcutManager
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 720),
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

        let metricColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("metric"))
        metricTable.addTableColumn(metricColumn)
        metricTable.headerView = nil
        metricTable.rowHeight = 18
        metricTable.dataSource = self
        metricTable.delegate = self
        metricTable.allowsMultipleSelection = false
        metricTable.style = .plain
        metricTable.setAccessibilityLabel("Menu bar metrics, in order")
        metricScroll.documentView = metricTable
        metricScroll.hasVerticalScroller = true
        metricScroll.borderType = .bezelBorder
        metricScroll.translatesAutoresizingMaskIntoConstraints = false
        metricScroll.heightAnchor.constraint(equalToConstant: 96).isActive = true

        addMetricPopUp.target = self
        addMetricPopUp.action = #selector(addMetric)
        addMetricPopUp.controlSize = .small
        addMetricPopUp.font = SearoomFont.system(11)
        addMetricPopUp.setAccessibilityLabel("Add a menu-bar metric")
        for button in [moveMetricUpButton, moveMetricDownButton, removeMetricButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
        }
        moveMetricUpButton.action = #selector(moveMetricUp)
        moveMetricDownButton.action = #selector(moveMetricDown)
        removeMetricButton.action = #selector(removeMetric)
        moveMetricUpButton.setAccessibilityLabel("Move the selected metric earlier")
        moveMetricDownButton.setAccessibilityLabel("Move the selected metric later")
        removeMetricButton.setAccessibilityLabel("Remove the selected metric")

        layoutControl.target = self
        layoutControl.action = #selector(layoutChanged)
        layoutControl.controlSize = .small
        layoutControl.setAccessibilityLabel("Menu bar layout")
        layoutControl.toolTip =
            "Stacked puts each value under its label in about half the width. Inline keeps one larger line."

        // Lists the metrics and their live values. Stacked renders these in
        // about half this width, so read it for content and order rather than
        // as a literal picture of the menu bar.
        metricPreview.font = SearoomFont.metric(10)
        metricPreview.textColor = .secondaryLabelColor
        metricPreview.lineBreakMode = .byTruncatingTail
        metricPreview.setAccessibilityLabel("Menu bar preview")

        let metricButtons = NSStackView(views: [
            addMetricPopUp, moveMetricUpButton, moveMetricDownButton, removeMetricButton
        ])
        metricButtons.orientation = .horizontal
        metricButtons.alignment = .centerY
        metricButtons.spacing = 6
        let metricControls = NSStackView(views: [metricScroll, metricButtons, metricPreview])
        metricControls.orientation = .vertical
        metricControls.alignment = .leading
        metricControls.spacing = 6
        metricControls.toolTip =
            "Choose up to \(MenuBarMetric.maximumCount) metrics. With none chosen the menu bar shows only the Searoom mark."
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

        let orderColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("section"))
        orderColumn.title = "Card"
        orderTable.addTableColumn(orderColumn)
        orderTable.headerView = nil
        orderTable.rowHeight = 18
        orderTable.dataSource = self
        orderTable.delegate = self
        orderTable.allowsMultipleSelection = false
        orderTable.allowsEmptySelection = false
        orderTable.style = .plain
        orderTable.setAccessibilityLabel("Dashboard card order")
        orderScroll.documentView = orderTable
        orderScroll.hasVerticalScroller = true
        orderScroll.borderType = .bezelBorder
        orderScroll.translatesAutoresizingMaskIntoConstraints = false
        orderScroll.heightAnchor.constraint(equalToConstant: 112).isActive = true

        for button in [moveUpButton, moveDownButton, resetOrderButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
        }
        moveUpButton.action = #selector(moveSectionUp)
        moveDownButton.action = #selector(moveSectionDown)
        resetOrderButton.action = #selector(resetSectionOrder)
        moveUpButton.setAccessibilityLabel("Move the selected card earlier")
        moveDownButton.setAccessibilityLabel("Move the selected card later")
        resetOrderButton.setAccessibilityLabel("Restore the default card order")

        let orderButtons = NSStackView(views: [moveUpButton, moveDownButton, resetOrderButton])
        orderButtons.orientation = .horizontal
        orderButtons.alignment = .centerY
        orderButtons.spacing = 6
        let orderGroup = NSStackView(views: [orderScroll, orderButtons])
        orderGroup.orientation = .vertical
        orderGroup.alignment = .leading
        orderGroup.spacing = 6
        orderGroup.toolTip = "Cards can also be dragged directly on the dashboard."

        let grid = NSGridView(views: [
            [makeLabel("MENU BAR", size: 10, color: .secondaryLabelColor), metricControls],
            [makeLabel("LAYOUT", size: 10, color: .secondaryLabelColor), layoutControl],
            [makeLabel("GLOBAL SHORTCUT", size: 10, color: .secondaryLabelColor), shortcutGroup],
            [makeLabel("SAMPLE RATE", size: 10, color: .secondaryLabelColor), intervalPopUp],
            [makeLabel("TREND WINDOW", size: 10, color: .secondaryLabelColor), historyPopUp],
            [makeLabel("CARD ORDER", size: 10, color: .secondaryLabelColor), orderGroup]
        ])
        grid.rowSpacing = 14
        grid.columnSpacing = 24
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .fill
        grid.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(grid)

        let storageActions = NSStackView(views: [updatesButton, resetHistoryButton])
        storageActions.orientation = .horizontal
        storageActions.alignment = .centerY
        storageActions.spacing = 8
        let storageSpacer = NSView()
        storageSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        storageSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let storageControls = NSStackView(views: [launchButton, storageSpacer, storageActions])
        storageControls.orientation = .horizontal
        storageControls.alignment = .centerY
        storageControls.distribution = .fill
        storageControls.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(storageControls)

        let noteWidth = (window.contentView?.bounds.width ?? 470) - 48
        let historyNote = makeHistoryNote(width: noteWidth)
        historyNote.note.delegate = self
        historyNote.note.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(historyNote.note)

        // The version belongs here rather than in a separate row: it is reference
        // information, not a control, and it replaces the "no network access"
        // claim that the user-initiated update check made untrue.
        let version = UpdateChecker.currentVersion
        let license = makeLabel(
            "SEAROOM \(version) · OPEN SOURCE · MIT",
            size: 8,
            color: .secondaryLabelColor
        )
        license.setAccessibilityLabel(
            "Searoom version \(version). Open source and MIT licensed."
        )
        license.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(license)

        githubButton.isBordered = false
        githubButton.font = SearoomFont.metric(8)
        githubButton.contentTintColor = .secondaryLabelColor
        githubButton.alignment = .right
        githubButton.target = self
        githubButton.action = #selector(openGitHubRepository)
        githubButton.toolTip = "https://github.com/emaitchess/searoom"
        githubButton.setAccessibilityLabel("Searoom on GitHub")
        githubButton.setAccessibilityHelp("Opens the Searoom repository in your default browser")
        githubButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(githubButton)

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
            historyNote.note.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            historyNote.note.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            historyNote.note.topAnchor.constraint(equalTo: storageControls.bottomAnchor, constant: 20),
            historyNote.note.heightAnchor.constraint(equalToConstant: historyNote.height),
            license.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            license.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -19),
            emaitchessButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            emaitchessButton.firstBaselineAnchor.constraint(equalTo: license.firstBaselineAnchor),
            githubButton.trailingAnchor.constraint(equalTo: emaitchessButton.leadingAnchor, constant: -12),
            githubButton.firstBaselineAnchor.constraint(equalTo: license.firstBaselineAnchor),
            githubButton.leadingAnchor.constraint(greaterThanOrEqualTo: license.trailingAnchor, constant: 12)
        ])
    }

    private func syncFromModel() {
        menuBarMetrics = model.settings.menuBarMetrics
        metricTable.reloadData()
        layoutControl.selectedSegment =
            MenuBarLayout.allCases.firstIndex(of: model.settings.menuBarLayout) ?? 0
        syncMetricControls()
        let intervals = AppSettings.supportedSampleIntervals
        intervalPopUp.selectItem(at: intervals.firstIndex(of: model.settings.sampleInterval) ?? 1)
        let historyValues = AppSettings.supportedHistoryMinutes
        historyPopUp.selectItem(at: historyValues.firstIndex(of: model.settings.historyMinutes) ?? 1)
        shortcutRecorder.shortcut = model.settings.globalShortcut
        shortcutClearButton.isEnabled = model.settings.globalShortcut != nil
        launchButton.state = SMAppService.mainApp.status == .enabled ? .on : .off
        sectionOrder = model.settings.dashboardSectionOrder
        let selected = orderTable.selectedRow
        orderTable.reloadData()
        if sectionOrder.indices.contains(selected) {
            orderTable.selectRowIndexes([selected], byExtendingSelection: false)
        }
        syncOrderButtons()
    }

    private func syncOrderButtons() {
        let row = orderTable.selectedRow
        moveUpButton.isEnabled = row > 0
        moveDownButton.isEnabled = row >= 0 && row < sectionOrder.count - 1
    }

    private func moveSelectedSection(by offset: Int) {
        let row = orderTable.selectedRow
        let destination = row + offset
        guard sectionOrder.indices.contains(row), sectionOrder.indices.contains(destination) else {
            return
        }
        let moved = DashboardSection.reordered(sectionOrder, moving: sectionOrder[row], to: destination)
        model.setDashboardSectionOrder(moved)
        sectionOrder = model.settings.dashboardSectionOrder
        orderTable.reloadData()
        orderTable.selectRowIndexes([destination], byExtendingSelection: false)
        syncOrderButtons()
    }

    @objc private func moveSectionUp() { moveSelectedSection(by: -1) }

    @objc private func moveSectionDown() { moveSelectedSection(by: 1) }

    @objc private func resetSectionOrder() {
        model.setDashboardSectionOrder(DashboardSection.defaults)
        sectionOrder = model.settings.dashboardSectionOrder
        orderTable.reloadData()
        syncOrderButtons()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === metricTable ? menuBarMetrics.count : sectionOrder.count
    }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let titles = tableView === metricTable
            ? menuBarMetrics.map(\.title)
            : sectionOrder.map(\.title)
        guard titles.indices.contains(row) else { return nil }
        let label = NSTextField(labelWithString: titles[row])
        label.font = .systemFont(ofSize: 11)
        label.setAccessibilityLabel("\(titles[row]), position \(row + 1) of \(titles.count)")
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView = notification.object as? NSTableView else { return }
        if tableView === metricTable { syncMetricControls() } else { syncOrderButtons() }
    }

    private func applyMenuBarMetrics(_ metrics: [MenuBarMetric], select row: Int?) {
        model.updateSettings { $0.menuBarMetrics = MenuBarMetric.normalized(metrics) }
        menuBarMetrics = model.settings.menuBarMetrics
        metricTable.reloadData()
        if let row, menuBarMetrics.indices.contains(row) {
            metricTable.selectRowIndexes([row], byExtendingSelection: false)
        }
        syncMetricControls()
    }

    /// Rebuilds the add list and the enabled states. The popup lists only what
    /// is not already chosen, so a duplicate cannot be requested.
    private func syncMetricControls() {
        let available = MenuBarMetric.allCases.filter { !menuBarMetrics.contains($0) }
        addMetricPopUp.removeAllItems()
        addMetricPopUp.addItem(withTitle: "Add Metric…")
        addMetricPopUp.addItems(withTitles: available.map(\.title))
        addMetricPopUp.selectItem(at: 0)
        addMetricPopUp.isEnabled = !available.isEmpty
            && menuBarMetrics.count < MenuBarMetric.maximumCount

        let row = metricTable.selectedRow
        let hasSelection = menuBarMetrics.indices.contains(row)
        moveMetricUpButton.isEnabled = hasSelection && row > 0
        moveMetricDownButton.isEnabled = hasSelection && row < menuBarMetrics.count - 1
        removeMetricButton.isEnabled = hasSelection

        metricPreview.stringValue = menuBarMetrics.isEmpty
            ? "Mark only"
            : model.menuBarText
        metricPreview.toolTip = "\(menuBarMetrics.count) of \(MenuBarMetric.maximumCount) selected"
    }

    @objc private func layoutChanged() {
        let index = max(0, layoutControl.selectedSegment)
        guard MenuBarLayout.allCases.indices.contains(index) else { return }
        model.updateSettings { $0.menuBarLayout = MenuBarLayout.allCases[index] }
        syncMetricControls()
    }

    @objc private func addMetric() {
        let available = MenuBarMetric.allCases.filter { !menuBarMetrics.contains($0) }
        let index = addMetricPopUp.indexOfSelectedItem - 1
        guard available.indices.contains(index) else { return }
        applyMenuBarMetrics(menuBarMetrics + [available[index]], select: menuBarMetrics.count)
    }

    @objc private func removeMetric() {
        let row = metricTable.selectedRow
        guard menuBarMetrics.indices.contains(row) else { return }
        var metrics = menuBarMetrics
        metrics.remove(at: row)
        applyMenuBarMetrics(metrics, select: min(row, metrics.count - 1))
    }

    private func moveMetric(by offset: Int) {
        let row = metricTable.selectedRow
        let destination = row + offset
        guard menuBarMetrics.indices.contains(row),
              menuBarMetrics.indices.contains(destination) else { return }
        var metrics = menuBarMetrics
        metrics.swapAt(row, destination)
        applyMenuBarMetrics(metrics, select: destination)
    }

    @objc private func moveMetricUp() { moveMetric(by: -1) }

    @objc private func moveMetricDown() { moveMetric(by: 1) }

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

    @objc private func openGitHubRepository() {
        guard let url = URL(string: "https://github.com/emaitchess/searoom") else { return }
        NSWorkspace.shared.open(url)
    }

    /// The history directory only exists once the first persistence pass has
    /// run, so the click creates it rather than opening a path Finder cannot
    /// show. History writes take the same directory.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL, url.isFileURL else { return false }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
        return true
    }

    private func makeHistoryNote(width: CGFloat) -> (note: NSTextView, height: CGFloat) {
        let note = NSTextView()
        note.isEditable = false
        note.isSelectable = true
        note.isRichText = false
        note.drawsBackground = false
        note.isVerticallyResizable = false
        note.isHorizontallyResizable = false
        note.textContainer?.widthTracksTextView = true
        note.textContainer?.lineFragmentPadding = 0
        note.textContainerInset = .zero

        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: SearoomFont.system(11),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let text = NSMutableAttributedString(
            string: "CPU pressure is a derived saturation signal. Temperature, fan and GPU readings are best-effort because macOS does not expose universal public APIs for them. Unsupported sensors remain clearly unavailable. All history stays in ",
            attributes: baseAttributes
        )
        text.append(NSAttributedString(
            string: "~/Library/Application Support/Searoom",
            attributes: [
                .font: SearoomFont.system(11),
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .link: historyDirectoryURL
            ]
        ))
        text.append(NSAttributedString(string: ".", attributes: baseAttributes))
        note.textStorage?.setAttributedString(text)

        guard let container = note.textContainer else { return (note, 0) }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        note.layoutManager?.ensureLayout(for: container)
        let measuredHeight = note.layoutManager?.usedRect(for: container).height ?? 0
        return (note, ceil(measuredHeight))
    }

    private var historyDirectoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Searoom", isDirectory: true)
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
