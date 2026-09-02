import Foundation

extension Notification.Name {
    static let searoomSampleUpdated = Notification.Name("SearoomSampleUpdated")
    static let searoomSettingsUpdated = Notification.Name("SearoomSettingsUpdated")
}

@MainActor
final class AppModel {
    private(set) var currentSample = SystemSample.placeholder
    private(set) var history = RingBuffer<SystemSample>()
    private(set) var settings: AppSettings
    private(set) var dashboardUnitState = DashboardUnitState()

    private let persistence = HistoryPersistence()
    private let defaultsKey = "Searoom.Settings.v1"
    private var lastPersistenceDate = Date.distantPast
    private var hasResetHistorySinceLaunch = false

    init() {
        settings = Self.loadSettings(key: defaultsKey)
        persistence.load { [weak self] samples in
            guard let self else { return }
            guard !self.hasResetHistorySinceLaunch else { return }
            self.history.replaceContents(samples, maximumCount: self.maximumHistoryCount)
            if let last = samples.last { self.currentSample = last }
            self.pruneHistory()
            NotificationCenter.default.post(name: .searoomSampleUpdated, object: self)
        }
    }

    func consume(_ sample: SystemSample) {
        currentSample = sample
        history.append(sample, maximumCount: maximumHistoryCount)
        pruneHistory()

        if Date.now.timeIntervalSince(lastPersistenceDate) >= 60 {
            lastPersistenceDate = .now
            persistence.save(history.snapshot())
        }
        NotificationCenter.default.post(name: .searoomSampleUpdated, object: self)
    }

    func updateSettings(_ transform: (inout AppSettings) -> Void) {
        transform(&settings)
        settings.normalize()
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        pruneHistory()
        NotificationCenter.default.post(name: .searoomSettingsUpdated, object: self)
        NotificationCenter.default.post(name: .searoomSampleUpdated, object: self)
    }

    func cycleDashboardUnit(_ target: DashboardUnitTarget) {
        dashboardUnitState.cycle(target)
    }

    func setDashboardSectionOrder(_ order: [DashboardSection]) {
        updateSettings { $0.dashboardSectionOrder = DashboardSection.normalized(order) }
    }

    func flushHistory() {
        persistence.save(history.snapshot())
    }

    func resetHistory() {
        hasResetHistorySinceLaunch = true
        history.removeAll(keepingCapacity: true)
        lastPersistenceDate = .now
        persistence.clear()
        NotificationCenter.default.post(name: .searoomSampleUpdated, object: self)
    }

    private func pruneHistory() {
        let cutoff = Date.now.addingTimeInterval(-TimeInterval(settings.historyMinutes * 60))
        history.removeFirst(while: { $0.timestamp < cutoff }, keepingAtLeast: 1)
        history.trim(to: maximumHistoryCount)
    }

    // A hard cap prevents corrupt settings or a clock jump from growing memory.
    private var maximumHistoryCount: Int {
        max(
            120,
            Int(Double(settings.historyMinutes * 60) / max(1, settings.sampleInterval)) + 2
        )
    }

    private static func loadSettings(key: String) -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return settings
    }
}

private final class HistoryPersistence: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.searoom.history", qos: .utility)

    func load(completion: @escaping @MainActor @Sendable ([SystemSample]) -> Void) {
        queue.async {
            guard let data = try? Data(contentsOf: self.fileURL),
                  let archive = try? PropertyListDecoder().decode(Archive.self, from: data),
                  archive.version == 1
            else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            DispatchQueue.main.async { completion(archive.samples) }
        }
    }

    func save(_ samples: [SystemSample]) {
        queue.async {
            let archive = Archive(version: 1, samples: samples)
            guard let data = try? PropertyListEncoder.binary.encode(archive) else { return }
            let directory = self.fileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: self.fileURL, options: [.atomic])
        }
    }

    func clear() {
        queue.async {
            guard FileManager.default.fileExists(atPath: self.fileURL.path) else { return }
            try? FileManager.default.removeItem(at: self.fileURL)
        }
    }

    private var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Searoom", isDirectory: true)
            .appendingPathComponent("history.plist")
    }

    private struct Archive: Codable, Sendable {
        let version: Int
        let samples: [SystemSample]
    }
}

private extension PropertyListEncoder {
    static var binary: PropertyListEncoder {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return encoder
    }
}
