import Foundation

/// Measures how long the current overall pressure level has been held
/// continuously across the retained sample history. The window is bounded by
/// the history the app keeps, so a run that spans every retained sample is
/// flagged as a floor rather than an exact duration.
enum SustainedPressure {
    struct Reading: Equatable, Sendable {
        let level: PressureLevel
        let duration: TimeInterval
        let boundedByHistoryWindow: Bool
    }

    static func duration<Samples: BidirectionalCollection>(
        in samples: Samples
    ) -> Reading? where Samples.Element == SystemSample {
        guard let newest = samples.last else { return nil }
        let level = newest.overallPressureLevel
        guard level != .unavailable else { return nil }

        var runStart = newest.timestamp
        var boundedByHistoryWindow = true
        for sample in samples.reversed() {
            guard sample.overallPressureLevel == level else {
                boundedByHistoryWindow = false
                break
            }
            runStart = sample.timestamp
        }
        return Reading(
            level: level,
            duration: max(0, newest.timestamp.timeIntervalSince(runStart)),
            boundedByHistoryWindow: boundedByHistoryWindow
        )
    }
}
