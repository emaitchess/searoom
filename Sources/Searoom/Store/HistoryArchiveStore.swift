import Foundation

/// The versioned local trend archive codec and its location, shared by the
/// app (on its utility queue) and the CLI (synchronously). Extracted from the
/// private codec that used to live inside `AppModel.swift`.
///
/// Archive format: a binary property list `Archive(version: 1, samples:)`.
/// Readers accept missing files as empty; corrupt, unsupported, and oversized
/// inputs are distinguished so the CLI can diagnose them while the app fails
/// closed to an empty history.
struct HistoryArchiveStore {
    enum LoadOutcome: Equatable {
        case samples([SystemSample])
        case missing
        case corrupt(String)
        case unsupported(version: Int?)
        case oversized
    }

    struct Limits: Equatable {
        let maximumFileSizeBytes: Int
        let maximumSampleCount: Int

        /// Deliberately above what any supported window can produce
        /// (`AppModel.maximumStoredSamples` is 10,800) but far below anything
        /// a hostile or corrupt file could grow to.
        static let conservative = Limits(
            maximumFileSizeBytes: 64 * 1_048_576,
            maximumSampleCount: 50_000
        )
    }

    struct Archive: Codable, Equatable {
        let version: Int
        let samples: [SystemSample]
    }

    static let archiveVersion = 1

    let fileURL: URL
    let limits: Limits

    init(fileURL: URL, limits: Limits = .conservative) {
        self.fileURL = fileURL
        self.limits = limits
    }

    /// Synchronous read. Never throws; the outcome enumerates every failure
    /// mode so callers decide between diagnosis and fail-closed behavior.
    func load() -> LoadOutcome {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        } catch {
            return .missing
        }
        let fileSize = attributes[.size] as? Int ?? 0
        guard fileSize <= limits.maximumFileSizeBytes else { return .oversized }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            return .corrupt("cannot read \(fileURL.path): \(error.localizedDescription)")
        }
        let archive: Archive
        do {
            archive = try PropertyListDecoder().decode(Archive.self, from: data)
        } catch {
            return .corrupt("not a decodable Searoom history archive: \(error.localizedDescription)")
        }
        guard archive.version == Self.archiveVersion else {
            return .unsupported(version: archive.version)
        }
        guard archive.samples.count <= limits.maximumSampleCount else { return .oversized }
        return .samples(archive.samples)
    }

    /// Atomic write. Returns false when encoding or writing failed so the
    /// caller can decide whether that is fatal. No cross-process lock: atomic
    /// replacement means a reader sees either the complete old or the
    /// complete new archive.
    @discardableResult
    func save(_ samples: [SystemSample]) -> Bool {
        guard let data = try? PropertyListEncoder.binary.encode(
            Archive(version: Self.archiveVersion, samples: samples)
        ) else { return false }
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    func clear() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    static func defaultArchiveURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Searoom", isDirectory: true)
            .appendingPathComponent("history.plist")
    }
}

private extension PropertyListEncoder {
    static var binary: PropertyListEncoder {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return encoder
    }
}
