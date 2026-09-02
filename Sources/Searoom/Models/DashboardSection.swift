import Foundation

/// One movable block on the dashboard.
///
/// The header, the Searoom self strip, and the footer are deliberately absent.
/// `DESIGN.md` pins the accountability strip immediately before the footer, so
/// neither it nor the chrome around it takes part in reordering.
enum DashboardSection: String, CaseIterable, Codable, Sendable {
    case cpu
    case memory
    case gpu
    case thermal
    case gpuMemory
    case disk
    case network
    case info
    case extras

    /// The shipped arrangement: primary resource cards before secondary
    /// hardware and process detail, which is what `DESIGN.md` asks of the
    /// default. A reader who reorders is overriding that default knowingly.
    static let defaults: [DashboardSection] = [
        .cpu, .memory, .gpu, .thermal, .gpuMemory, .disk, .network, .info, .extras
    ]

    /// Title case, for the Settings reorder list. The cards draw their own
    /// uppercase micro-labels; these names match them so the list and the
    /// dashboard cannot be read as describing different things.
    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .gpu: "GPU"
        case .thermal: "Thermal"
        case .gpuMemory: "GPU Memory"
        case .disk: "Disk"
        case .network: "Network I/O"
        case .info: "Fan and Uptime"
        case .extras: "Engine Room"
        }
    }

    /// Full-width sections span the content width and close any half-width row
    /// that is still open above them.
    var isFullWidth: Bool {
        switch self {
        case .cpu, .memory, .gpu, .thermal, .gpuMemory, .disk: false
        case .network, .info, .extras: true
        }
    }

    var height: CGFloat {
        switch self {
        case .cpu, .memory, .gpu, .thermal, .gpuMemory, .disk: 158
        case .network: 122
        case .info: 88
        case .extras: 180
        }
    }

    /// Moves `section` to `index`, returning a normalized order. Pure, so a
    /// move can be tested without a view, a drag, or a settings store.
    static func reordered(
        _ order: [DashboardSection],
        moving section: DashboardSection,
        to index: Int
    ) -> [DashboardSection] {
        var result = order
        result.removeAll { $0 == section }
        result.insert(section, at: min(max(0, index), result.count))
        return normalized(result)
    }

    /// Every section is always shown; only the order is user data. Unknown,
    /// duplicated, and missing entries are repaired rather than rejected, the
    /// way `MenuBarMetric.normalized` repairs the custom menu-bar slots. A
    /// section dropped from a future build therefore cannot strand the rest.
    static func normalized(_ sections: [DashboardSection]) -> [DashboardSection] {
        var seen = Set<DashboardSection>()
        var result: [DashboardSection] = []
        for section in sections where seen.insert(section).inserted {
            result.append(section)
        }
        for section in defaults where seen.insert(section).inserted {
            result.append(section)
        }
        return result
    }
}
