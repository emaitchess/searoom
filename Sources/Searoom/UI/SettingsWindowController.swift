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
    private let moveMetricUpButton = NSButton(title: "↑", target: nil, action: nil)
    private let moveMetricDownButton = NSButton(title: "↓", target: nil, action: nil)
    private let removeMetricButton = NSButton(title: "✕", target: nil, action: nil)
    private let layoutControl = NSSegmentedControl(
        labels: MenuBarLayout.allCases.map(\.title),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private var menuBarMetrics: [MenuBarMetric] = MenuBarMetric.defaults
    private let intervalSlider = NSSlider()
    private let intervalValueLabel = NSTextField(labelWithString: "")
    private let historySlider = NSSlider()
    private let historyValueLabel = NSTextField(labelWithString: "")
    private let shortcutRecorder = ShortcutRecorderControl()
    private let shortcutClearButton = NSButton(title: "Clear", target: nil, action: nil)
    private let shortcutError = NSTextField(labelWithString: "")
    private let launchButton = NSSwitch()
    private let hapticsButton = NSSwitch()
    private let cliToggle = NSSwitch()
    private let agentSkillButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let agentSkillStatusLabel = NSTextField(labelWithString: "")
    /// Held so the whole row can be hidden while the command is off: a skill
    /// that tells a model to run `searoom` is useless without the command.
    private var agentSkillRow: NSGridRow?
    private weak var pageScrollView: NSScrollView?
    private let cliStatusLabel = NSTextField(labelWithString: "")
    private let resetHistoryButton = NSButton(title: "Reset Trend History", target: nil, action: nil)
    private let updatesButton = NSButton(title: "Check for Updates", target: nil, action: nil)
    private let githubButton = NSButton(title: "GITHUB ↗", target: nil, action: nil)
    private let emaitchessButton = NSButton(title: "PART OF EMAITCHESS ↗", target: nil, action: nil)
    private let orderTable = NSTableView()
    private let orderScroll = NSScrollView()
    private let moveUpButton = NSButton(title: "↑", target: nil, action: nil)
    private let moveDownButton = NSButton(title: "↓", target: nil, action: nil)
    private let resetOrderButton = NSButton(title: "Reset", target: nil, action: nil)
    /// Mirrors the persisted order so the table has a stable data source; the
    /// dashboard can also change it by drag, so `show()` re-reads the model.
    private var sectionOrder: [DashboardSection] = DashboardSection.defaults
    /// The last slider stop that produced haptic feedback, so one tap is felt
    /// per detent crossed rather than one per mouse-dragged event.
    private var lastHapticHistoryIndex = -1
    /// The same, for the sample-rate slider.
    private var lastHapticIntervalIndex = -1

    init(model: AppModel, shortcutManager: GlobalShortcutManager) {
        self.model = model
        self.shortcutManager = shortcutManager
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 720),
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
        // The subtitle is replaced by the result of the last skill action, so
        // reopening Settings puts the explanation back.
        resetAgentSkillSubtitle()
        syncFromModel()
        // Reopening should show the top of the page, not wherever it was left.
        pageScrollView?.documentView?.scroll(.zero)
        showWindow(nil)
        window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func configureContent() {
        guard let window else { return }
        // The window is the popover's size and stays that size. Everything
        // lives in a scroller, so a long settings page is a scroll rather than
        // a window that grows past the bottom of a laptop screen.
        let backdrop = SettingsBackgroundView()
        window.contentView = backdrop

        let scrollView = SearoomScrollView(frame: .zero)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        backdrop.addSubview(scrollView)
        pageScrollView = scrollView

        let root = SettingsBackgroundView()
        root.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = root
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: backdrop.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
            // Matching the clip view's width is what keeps the page from ever
            // scrolling sideways; the content column narrows instead.
            root.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor)
        ])

        let metricColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("metric"))
        metricTable.addTableColumn(metricColumn)
        metricTable.headerView = nil
        metricTable.rowHeight = Self.listRowHeight
        metricTable.dataSource = self
        metricTable.delegate = self
        metricTable.allowsMultipleSelection = false
        metricTable.style = .plain
        metricTable.setAccessibilityLabel("Menu bar metrics, in order")
        metricScroll.documentView = metricTable
        metricScroll.hasVerticalScroller = false
        metricScroll.borderType = .bezelBorder
        metricScroll.translatesAutoresizingMaskIntoConstraints = false
        // Tall enough for every row it can ever hold, so this list never
        // scrolls. A scroller inside the scrolling page would swallow the
        // wheel while the pointer was over it, which reads as the page
        // sticking and then lurching once the pointer moves off the list.
        metricScroll.heightAnchor.constraint(
            equalToConstant: Self.listHeight(rows: MenuBarMetric.maximumCount)
        ).isActive = true

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
        moveMetricUpButton.toolTip = "Move the selected metric earlier"
        moveMetricDownButton.setAccessibilityLabel("Move the selected metric later")
        moveMetricDownButton.toolTip = "Move the selected metric later"
        removeMetricButton.setAccessibilityLabel("Remove the selected metric")
        removeMetricButton.toolTip = "Remove the selected metric"

        layoutControl.target = self
        layoutControl.action = #selector(layoutChanged)
        layoutControl.controlSize = .small
        layoutControl.setAccessibilityLabel("Menu bar layout")
        layoutControl.toolTip =
            "Stacked puts each value under its label in about half the width. Inline keeps one larger line."

        let metricButtons = NSStackView(views: [
            addMetricPopUp, moveMetricUpButton, moveMetricDownButton, removeMetricButton
        ])
        metricButtons.orientation = .horizontal
        metricButtons.alignment = .centerY
        metricButtons.spacing = 6
        let metricControls = NSStackView(views: [metricScroll, metricButtons])
        metricControls.orientation = .vertical
        metricControls.alignment = .leading
        metricControls.spacing = 6
        metricControls.toolTip =
            "Choose up to \(MenuBarMetric.maximumCount) metrics. With none chosen the menu bar shows only the Searoom mark."
        // Same shape as the trend window below it: a track with ten stops and
        // the value named beside it. Ten radio buttons would not fit the column
        // and a pop-up hides nine choices behind a click.
        intervalSlider.sliderType = .linear
        intervalSlider.minValue = 0
        intervalSlider.maxValue = Double(AppSettings.supportedSampleIntervals.count - 1)
        intervalSlider.numberOfTickMarks = AppSettings.supportedSampleIntervals.count
        intervalSlider.allowsTickMarkValuesOnly = true
        intervalSlider.isContinuous = true
        intervalSlider.controlSize = .small
        intervalSlider.target = self
        intervalSlider.action = #selector(intervalChanged)
        intervalSlider.setAccessibilityLabel("Sample rate")
        intervalSlider.setAccessibilityHelp(
            "How often Searoom reads the system. Longer intervals cost less."
        )
        intervalValueLabel.font = SearoomFont.metric(11)
        intervalValueLabel.textColor = .secondaryLabelColor
        intervalValueLabel.alignment = .left
        intervalValueLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        // Pinned to the widest value for the same reason as the trend window:
        // otherwise the label resizes as the rate changes and slides the track
        // sideways under the thumb.
        let intervalFont = intervalValueLabel.font ?? SearoomFont.metric(11)
        let widestInterval = AppSettings.supportedSampleIntervals
            .map { AppSettings.sampleIntervalTitle($0) }
            .map { ($0 as NSString).size(withAttributes: [.font: intervalFont]).width }
            .max() ?? 0
        intervalValueLabel.widthAnchor
            .constraint(equalToConstant: ceil(widestInterval)).isActive = true

        let intervalGroup = NSStackView(views: [intervalSlider, intervalValueLabel])
        intervalGroup.orientation = .horizontal
        intervalGroup.spacing = 10
        intervalGroup.alignment = .centerY
        intervalSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // A slider rather than a menu: 26 stops read as a range, and a menu that
        // long is worse to scan than a track you can drag. Tick-only values keep
        // every position a real setting instead of an interpolated one.
        historySlider.sliderType = .linear
        historySlider.minValue = 0
        historySlider.maxValue = Double(AppSettings.supportedHistoryMinutes.count - 1)
        historySlider.numberOfTickMarks = AppSettings.supportedHistoryMinutes.count
        historySlider.allowsTickMarkValuesOnly = true
        historySlider.isContinuous = true
        historySlider.controlSize = .small
        historySlider.setAccessibilityLabel("Trend window")
        historyValueLabel.font = SearoomFont.metric(11)
        historyValueLabel.textColor = .secondaryLabelColor
        historyValueLabel.alignment = .left
        historyValueLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        // Pin the label to the widest value it will ever hold. Otherwise the
        // label resizes as the text changes and the slider slides sideways
        // under the thumb mid-drag, which is the one place a control must not
        // move. Measured once here rather than guessed: the widest is not the
        // longest window but "30 minutes".
        let valueFont = historyValueLabel.font ?? SearoomFont.metric(11)
        let widestValue = AppSettings.supportedHistoryMinutes
            .map { AppSettings.historyWindowTitle(minutes: $0) }
            .map { ($0 as NSString).size(withAttributes: [.font: valueFont]).width }
            .max() ?? 0
        historyValueLabel.widthAnchor
            .constraint(equalToConstant: ceil(widestValue)).isActive = true
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
        // An empty label still has intrinsic height, so leaving it in the stack
        // reserved a blank line under every shortcut row whether or not there
        // was an error. NSStackView detaches hidden arranged subviews, so
        // hiding it removes the space rather than merely blanking it.
        shortcutError.isHidden = true
        let shortcutGroup = NSStackView(views: [shortcutControls, shortcutError])
        shortcutGroup.orientation = .vertical
        shortcutGroup.alignment = .width
        shortcutGroup.spacing = 3

        historySlider.target = self
        historySlider.action = #selector(historyChanged)
        launchButton.target = self
        launchButton.action = #selector(launchChanged)
        // The row label carries the name now, so the checkbox has no title of
        // its own and needs one spelled out for VoiceOver.
        launchButton.setAccessibilityLabel("Launch Searoom at login")
        hapticsButton.target = self
        hapticsButton.action = #selector(hapticsChanged)
        hapticsButton.setAccessibilityLabel("Trackpad feedback")
        hapticsButton.setAccessibilityHelp(
            "Taps the trackpad at each slider stop, when the sample rate changes, "
                + "while scrubbing a chart, and when a dragged card would move. "
                + "Has no effect without a Force Touch trackpad."
        )
        resetHistoryButton.bezelStyle = .rounded
        resetHistoryButton.controlSize = .small
        resetHistoryButton.target = self
        resetHistoryButton.action = #selector(resetHistory)
        resetHistoryButton.setAccessibilityLabel("Reset saved trend history")
        cliToggle.target = self
        cliToggle.action = #selector(toggleCLICommand)
        cliToggle.setAccessibilityLabel("Enable the searoom terminal command")
        cliToggle.setAccessibilityHelp(
            "Creates ~/.local/bin/searoom as a symlink to this app, and adds that "
                + "folder to your PATH in ~/.zprofile if it is not there already."
        )
        cliStatusLabel.font = SearoomFont.system(10)
        cliStatusLabel.textColor = .secondaryLabelColor
        cliStatusLabel.lineBreakMode = .byTruncatingTail
        cliStatusLabel.setAccessibilityLabel("Terminal command status")
        // The switch is pushed to the trailing edge so the row reads as a
        // label and a toggle; the status line only appears when it has
        // something to say, which keeps the ordinary on and off states quiet.
        let cliSpacer = NSView()
        cliSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        cliSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let cliRow = NSStackView(views: [cliSpacer, cliToggle])
        cliRow.orientation = .horizontal
        cliRow.alignment = .centerY
        let cliGroup = NSStackView(views: [cliRow, cliStatusLabel])
        cliGroup.orientation = .vertical
        cliGroup.alignment = .leading
        cliGroup.spacing = 4
        // The status line is always present, even when it says nothing. It
        // reports states that only some machines ever reach — a Homebrew link,
        // a conflict — and letting it appear and disappear would resize the
        // window under the switch that was just clicked.
        NSLayoutConstraint.activate([
            cliRow.widthAnchor.constraint(equalTo: cliGroup.widthAnchor),
            cliStatusLabel.widthAnchor.constraint(equalTo: cliGroup.widthAnchor),
            cliStatusLabel.heightAnchor.constraint(equalToConstant: 13)
        ])
        cliGroup.toolTip = "Exposes the lowercase searoom command for terminal and agent use."

        agentSkillButton.bezelStyle = .rounded
        agentSkillButton.controlSize = .small
        agentSkillButton.setAccessibilityLabel("Add the Searoom skill to a coding agent")
        agentSkillStatusLabel.font = SearoomFont.system(10)
        agentSkillStatusLabel.textColor = .secondaryLabelColor
        agentSkillStatusLabel.lineBreakMode = .byTruncatingTail
        agentSkillStatusLabel.stringValue =
            "Teach coding agents when and how to use the Searoom CLI."
        agentSkillStatusLabel.setAccessibilityLabel("Agent skill status")
        let agentSkillGroup = NSStackView(views: [agentSkillButton, agentSkillStatusLabel])
        agentSkillGroup.orientation = .vertical
        agentSkillGroup.alignment = .leading
        agentSkillGroup.spacing = 4
        agentSkillGroup.toolTip =
            "Writes one SKILL.md into each agent's own skills folder. Nothing else is changed."
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
        orderTable.rowHeight = Self.listRowHeight
        orderTable.dataSource = self
        orderTable.delegate = self
        orderTable.allowsMultipleSelection = false
        orderTable.allowsEmptySelection = false
        orderTable.style = .plain
        orderTable.setAccessibilityLabel("Dashboard card order")
        orderScroll.documentView = orderTable
        orderScroll.hasVerticalScroller = false
        orderScroll.borderType = .bezelBorder
        orderScroll.translatesAutoresizingMaskIntoConstraints = false
        orderScroll.heightAnchor.constraint(
            equalToConstant: Self.listHeight(rows: DashboardSection.allCases.count)
        ).isActive = true

        for button in [moveUpButton, moveDownButton, resetOrderButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
        }
        moveUpButton.action = #selector(moveSectionUp)
        moveDownButton.action = #selector(moveSectionDown)
        resetOrderButton.action = #selector(resetSectionOrder)
        moveUpButton.setAccessibilityLabel("Move the selected card earlier")
        moveUpButton.toolTip = "Move the selected card earlier"
        moveDownButton.setAccessibilityLabel("Move the selected card later")
        moveDownButton.toolTip = "Move the selected card later"
        resetOrderButton.setAccessibilityLabel("Restore the default card order")
        resetOrderButton.toolTip = "Restore the default card order"

        let orderButtons = NSStackView(views: [moveUpButton, moveDownButton, resetOrderButton])
        orderButtons.orientation = .horizontal
        orderButtons.alignment = .centerY
        orderButtons.spacing = 6
        let orderGroup = NSStackView(views: [orderScroll, orderButtons])
        orderGroup.orientation = .vertical
        orderGroup.alignment = .leading
        orderGroup.spacing = 6
        orderGroup.toolTip = "Cards can also be dragged directly on the dashboard."

        // The label sits beside the track rather than under it, so the row keeps
        // the same height as the other settings rows.
        let historyGroup = NSStackView(views: [historySlider, historyValueLabel])
        historyGroup.orientation = .horizontal
        historyGroup.spacing = 10
        historyGroup.alignment = .centerY
        historySlider.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Settings are grouped by what they change rather than by the order
        // they were built in: the two surfaces first, then what feeds them,
        // then the command line, the app's own behaviour, and the actions.
        // Section rows carry a marker view in the second column so the header
        // can be found and merged after the grid exists.
        let sections: [(String, [(String, NSView)])] = [
            ("MENU BAR", [
                ("Metrics", metricControls),
                ("Layout", layoutControl),
            ]),
            ("DASHBOARD", [
                ("Cards", orderGroup),
            ]),
            ("SAMPLING", [
                ("Interval", intervalGroup),
                ("Trend window", historyGroup),
            ]),
            ("SEAROOM CLI", [
                ("Command", cliGroup),
                (agentSkillRowLabel, agentSkillGroup),
            ]),
            ("GENERAL", [
                ("Shortcut", shortcutGroup),
                ("Launch at login", trailing(launchButton)),
                ("Trackpad feedback", trailing(hapticsButton)),
            ]),
            ("MAINTENANCE", [
                ("Updates", leading(updatesButton)),
                ("Trend history", leading(resetHistoryButton)),
            ]),
        ]

        var gridRows: [[NSView]] = []
        var headerRowIndices: [Int] = []
        var agentSkillRowIndex: Int?
        for (title, rows) in sections {
            headerRowIndices.append(gridRows.count)
            gridRows.append([makeSectionHeader(title), NSGridCell.emptyContentView])
            for (label, control) in rows {
                if label == agentSkillRowLabel { agentSkillRowIndex = gridRows.count }
                gridRows.append([makeLabel(label, size: 10, color: .secondaryLabelColor), control])
            }
        }

        let grid = NSGridView(views: gridRows)
        // A header spans both columns, so the section name is not squeezed into
        // the label column's width.
        for index in headerRowIndices {
            grid.mergeCells(
                inHorizontalRange: NSRange(location: 0, length: 2),
                verticalRange: NSRange(location: index, length: 1)
            )
            // Sections need air above them, but not before the first one.
            if index > 0 { grid.row(at: index).topPadding = 10 }
        }
        if let agentSkillRowIndex { agentSkillRow = grid.row(at: agentSkillRowIndex) }
        grid.rowSpacing = 8
        grid.columnSpacing = 18
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .fill
        grid.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(grid)


        let noteWidth = window.contentLayoutRect.width - 48
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
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            historyNote.note.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            historyNote.note.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            historyNote.note.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 20),
            historyNote.note.heightAnchor.constraint(equalToConstant: historyNote.height),
            // The note is the only variable-height element and the window cannot
            // scroll, so tie it to the footer. Without this the two are free to
            // overlap and the failure is silent.
            license.topAnchor.constraint(
                greaterThanOrEqualTo: historyNote.note.bottomAnchor, constant: 16
            ),
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
        let intervalIndex = intervals.firstIndex(of: model.settings.sampleInterval) ?? 1
        intervalSlider.integerValue = intervalIndex
        lastHapticIntervalIndex = intervalIndex
        updateIntervalLabel(interval: intervals[intervalIndex])
        let historyValues = AppSettings.supportedHistoryMinutes
        let historyIndex = historyValues.firstIndex(of: model.settings.historyMinutes) ?? 1
        historySlider.integerValue = historyIndex
        lastHapticHistoryIndex = historyIndex
        updateHistoryLabel(minutes: historyValues[historyIndex])
        shortcutRecorder.shortcut = model.settings.globalShortcut
        // Nothing to clear when nothing is set, and a permanently dead button
        // is worse than no button. The row keeps its height either way.
        shortcutClearButton.isHidden = model.settings.globalShortcut == nil
        launchButton.state = SMAppService.mainApp.status == .enabled ? .on : .off
        hapticsButton.state = model.settings.hapticsEnabled ? .on : .off
        sectionOrder = model.settings.dashboardSectionOrder
        let selected = orderTable.selectedRow
        orderTable.reloadData()
        if sectionOrder.indices.contains(selected) {
            orderTable.selectRowIndexes([selected], byExtendingSelection: false)
        }
        syncOrderButtons()
        // Reads the filesystem, so it belongs in the same pass that reads the
        // model: without it the switch and the agent-skills row keep whatever
        // state the window was built with until someone touches a control.
        syncCLIControls()
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

    /// Drives the toggle from the filesystem rather than from a stored flag,
    /// so what it shows is what a terminal would find. Reports installed,
    /// externally managed, absent, conflict, unstable-location, and
    /// PATH-visibility states without changing anything.
    private func syncCLIControls() {
        var enabled = false
        switch CLIInstaller.state() {
        case .installed(let pathVisible):
            enabled = true
            cliToggle.isEnabled = true
            // Nothing to report when it simply works.
            cliStatusLabel.stringValue = pathVisible
                ? ""
                : "~/.local/bin is not on your PATH yet, so the shell cannot find it."
        case .managedExternally(let path):
            enabled = true
            // Homebrew's link is not ours to remove, so the toggle reports it
            // rather than offering an off switch that would not work.
            cliToggle.isEnabled = false
            cliStatusLabel.stringValue = "Provided by \(path)."
        case .absent:
            cliToggle.isEnabled = true
            cliStatusLabel.stringValue = ""
        case .conflict:
            cliToggle.isEnabled = false
            cliStatusLabel.stringValue = "~/.local/bin/searoom exists and is not Searoom's link."
        case .unstableLocation(let reason):
            cliToggle.isEnabled = false
            cliStatusLabel.stringValue = reason
        }
        cliToggle.state = enabled ? .on : .off
        syncAgentSkillControls(commandEnabled: enabled)
    }

    /// The skill tells an agent to run `searoom`, so the row only exists while
    /// the command does. Each agent is a checkable item: on installs, off
    /// removes, and a dash means the file is there but is not this version.
    private func syncAgentSkillControls(commandEnabled: Bool) {
        agentSkillRow?.isHidden = !commandEnabled
        guard commandEnabled else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        // A pull-down menu shows item zero as its title and never selects it.
        menu.addItem(withTitle: "Add skill to…", action: nil, keyEquivalent: "")
        let everywhere = NSMenuItem(
            title: "Install to all agents",
            action: #selector(installAgentSkillEverywhere),
            keyEquivalent: ""
        )
        everywhere.target = self
        menu.addItem(everywhere)
        menu.addItem(.separator())
        for (index, target) in AgentSkillInstaller.targets.enumerated() {
            let item = NSMenuItem(
                title: target.displayName,
                action: #selector(toggleAgentSkill(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = index
            switch AgentSkillInstaller.state(for: target) {
            case .current:
                item.state = .on
            case .outdated:
                item.state = .mixed
            case .absent:
                item.state = .off
            case .blocked(let reason):
                item.state = .off
                item.isEnabled = false
                item.toolTip = reason
            }
            menu.addItem(item)
        }
        agentSkillButton.menu = menu
    }

    private func resetAgentSkillSubtitle() {
        agentSkillStatusLabel.stringValue =
            "Teach coding agents when and how to use the Searoom CLI."
    }

    @objc private func toggleCLICommand() {
        let turningOn = cliToggle.state == .on
        let outcome = turningOn ? CLIInstaller.install() : CLIInstaller.uninstall()
        // The PATH entry travels with the link: a command the shell cannot
        // find is not installed, and one left behind after removal is litter.
        if turningOn {
            if outcome.exitCode == 0 { CLIInstaller.addBinDirectoryToPath(homeDirectory: NSHomeDirectory()) }
        } else {
            CLIInstaller.removeBinDirectoryFromPath(homeDirectory: NSHomeDirectory())
        }
        // Records the decision, so first-launch linking does not put the
        // command back after someone has deliberately turned it off.
        model.updateSettings { $0.cliLinkDeclined = !turningOn }
        Haptics.tap(.generic, enabled: model.settings.hapticsEnabled)
        syncCLIControls()
        // The resolved state is the honest report, so it wins; a failure that
        // leaves no trace in that state would otherwise pass silently.
        if outcome.exitCode != 0 {
            cliStatusLabel.stringValue = outcome.message
        }
    }

    @objc private func toggleAgentSkill(_ sender: NSMenuItem) {
        guard AgentSkillInstaller.targets.indices.contains(sender.tag) else { return }
        let target = AgentSkillInstaller.targets[sender.tag]
        let outcome: AgentSkillInstaller.Outcome
        switch AgentSkillInstaller.state(for: target) {
        case .current:
            outcome = AgentSkillInstaller.remove(target)
        case .outdated, .absent:
            outcome = AgentSkillInstaller.install(target)
        case .blocked(let reason):
            outcome = AgentSkillInstaller.Outcome(installed: false, message: reason)
        }
        agentSkillStatusLabel.stringValue = outcome.message
        Haptics.tap(.generic, enabled: model.settings.hapticsEnabled)
        syncCLIControls()
    }

    @objc private func installAgentSkillEverywhere() {
        let outcome = AgentSkillInstaller.installAll()
        agentSkillStatusLabel.stringValue = outcome.message
        Haptics.tap(.generic, enabled: model.settings.hapticsEnabled)
        syncCLIControls()
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

        metricScroll.toolTip = "\(menuBarMetrics.count) of \(MenuBarMetric.maximumCount) selected"
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
        let index = min(values.count - 1, max(0, intervalSlider.integerValue))
        let value = values[index]

        if index != lastHapticIntervalIndex {
            lastHapticIntervalIndex = index
            Haptics.tap(.levelChange, enabled: model.settings.hapticsEnabled)
        }
        updateIntervalLabel(interval: value)

        // Committing mid-drag matters more here than on the trend slider:
        // AppDelegate restarts the sampling timer whenever this value changes,
        // so writing on every tick would tear down and rebuild the timer up to
        // nine times for one gesture.
        let isStillDragging = NSApp.currentEvent?.type == .leftMouseDragged
        guard !isStillDragging, value != model.settings.sampleInterval else { return }
        model.updateSettings { $0.sampleInterval = value }
    }

    private func updateIntervalLabel(interval: TimeInterval) {
        let title = AppSettings.sampleIntervalTitle(interval)
        intervalValueLabel.stringValue = title
        intervalSlider.setAccessibilityValueDescription(title)
    }

    @objc private func historyChanged() {
        let values = AppSettings.supportedHistoryMinutes
        let index = min(values.count - 1, max(0, historySlider.integerValue))
        let value = values[index]

        // One tap per detent crossed. NSHapticFeedbackManager is part of AppKit,
        // so this adds no dependency and no bundle weight, and it is a no-op on
        // hardware without a Force Touch trackpad. .levelChange is the pattern
        // macOS uses for a slider passing a detent.
        if index != lastHapticHistoryIndex {
            lastHapticHistoryIndex = index
            Haptics.tap(.levelChange, enabled: model.settings.hapticsEnabled)
        }

        // The label follows the thumb, but the setting is only written when the
        // drag ends. The slider is continuous and has 26 stops, so committing on
        // every tick would write settings up to 25 times for one gesture, and
        // each write encodes JSON, hits UserDefaults, reprunes history and posts
        // two notifications that redraw the dashboard and the menu bar.
        updateHistoryLabel(minutes: value)
        let isStillDragging = NSApp.currentEvent?.type == .leftMouseDragged
        guard !isStillDragging, value != model.settings.historyMinutes else { return }
        model.updateSettings { $0.historyMinutes = value }
    }

    private func updateHistoryLabel(minutes: Int) {
        historyValueLabel.stringValue = AppSettings.historyWindowTitle(minutes: minutes)
        historySlider.setAccessibilityValueDescription(
            AppSettings.historyWindowTitle(minutes: minutes)
        )
    }

    @objc private func hapticsChanged() {
        let enabled = hapticsButton.state == .on
        model.updateSettings { $0.hapticsEnabled = enabled }
        // Confirm the setting with the thing it controls, so turning it on
        // demonstrates itself.
        Haptics.tap(.levelChange, enabled: enabled)
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
            setShortcutError(nil)
            model.updateSettings { $0.globalShortcut = nil }
            shortcutClearButton.isHidden = true
            return true
        }

        let status = shortcutManager.register(shortcut)
        guard status == noErr else {
            if let previous { _ = shortcutManager.register(previous) }
            setShortcutError("That shortcut is already in use.")
            return false
        }
        setShortcutError(nil)
        model.updateSettings { $0.globalShortcut = shortcut }
        shortcutClearButton.isHidden = false
        return true
    }

    private func setShortcutError(_ message: String?) {
        shortcutError.stringValue = message ?? ""
        shortcutError.isHidden = message == nil
    }

    /// A section title. Heavier than a row label and in the primary colour,
    /// so the eye can find the group boundaries without a rule or a box.
    private static let agentSkillRowLabelValue = "Agent skills"
    private var agentSkillRowLabel: String { Self.agentSkillRowLabelValue }

    /// Holds a control at the leading edge of its grid cell. The column is
    /// filled, so without this a button stretches the full width of the page.
    private func leading(_ view: NSView) -> NSStackView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [view, spacer])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        return stack
    }

    /// Pushes a control to the trailing edge of its grid cell, so the three
    /// switches line up on one edge instead of drifting with their widths.
    private func trailing(_ view: NSView) -> NSStackView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [spacer, view])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        return stack
    }

    /// Height of a bordered list showing `rows` whole rows and nothing more.
    private static func listHeight(rows: Int) -> CGFloat {
        CGFloat(rows) * listRowHeight + 2
    }

    private static let listRowHeight: CGFloat = 18

    private func makeSectionHeader(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = SearoomFont.metric(11)
        label.textColor = .labelColor
        label.setAccessibilityRole(.staticText)
        return label
    }

    private func makeLabel(_ text: String, size: CGFloat, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = SearoomFont.metric(size)
        label.textColor = color
        return label
    }
}

/// Closes on Command-W.
///
/// The app is an accessory, which means it never installs a menu bar, and
/// `NSApp.mainMenu` key equivalents are never matched: the existing Quit item's
/// Command-Q does nothing either. So the shortcut has to be handled by the
/// window that it should close. Closing leaves the app running in the menu bar,
/// which is the whole point of Command-W rather than Command-Q.
private final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
private final class SettingsBackgroundView: NSView {
    /// Flipped so the scroller's origin is the top of the page. An unflipped
    /// document view opens scrolled to the bottom.
    override var isFlipped: Bool { true }
    /// It fills its bounds with paper, so the scroller can copy on scroll.
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let theme = SearoomTheme(appearance: effectiveAppearance)
        theme.paper.setFill()
        bounds.fill()
    }
}
