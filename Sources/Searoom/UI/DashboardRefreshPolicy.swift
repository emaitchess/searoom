import Foundation

struct DashboardTrendRefreshPolicy: Sendable {
    static let interval: Duration = .seconds(5)

    private var lastRefresh: ContinuousClock.Instant?

    mutating func shouldRefresh(
        at now: ContinuousClock.Instant,
        force: Bool = false
    ) -> Bool {
        if force {
            lastRefresh = now
            return true
        }
        guard let lastRefresh else {
            self.lastRefresh = now
            return true
        }
        guard lastRefresh.duration(to: now) >= Self.interval else { return false }
        self.lastRefresh = now
        return true
    }

    mutating func reset() {
        lastRefresh = nil
    }
}

enum DashboardTrendSampleLocator {
    static func nearestIndex(
        to target: Date,
        count: Int,
        timestampAt: (Int) -> Date
    ) -> Int? {
        guard count > 0 else { return nil }

        var lower = 0
        var upper = count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if timestampAt(middle) < target {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower > 0 else { return 0 }
        guard lower < count else { return count - 1 }
        let before = timestampAt(lower - 1)
        let after = timestampAt(lower)
        return target.timeIntervalSince(before) <= after.timeIntervalSince(target)
            ? lower - 1
            : lower
    }
}

enum DashboardTrendMetric: CaseIterable, Hashable, Sendable {
    case cpu
    case memory
    case gpu
    case thermal
    case network

    var synchronizedMetrics: [DashboardTrendMetric] {
        switch self {
        case .cpu, .memory, .gpu, .thermal:
            [.cpu, .memory, .gpu, .thermal]
        case .network:
            [.network]
        }
    }
}
