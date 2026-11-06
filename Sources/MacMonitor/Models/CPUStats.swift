import Foundation

/// A snapshot of CPU utilization. All values are percentages (0–100).
///
/// Models are plain value types (`struct`) with no logic that touches the
/// system. That keeps them easy to test and safe to pass between threads
/// (`Sendable`).
struct CPUStats: Sendable, Equatable {
    var user: Double
    var system: Double
    var idle: Double
    /// Per-core usage, in the order the kernel reports them.
    var cores: [CoreUsage] = []

    /// Total "busy" time = user + system.
    var total: Double { min(100, user + system) }

    static let zero = CPUStats(user: 0, system: 0, idle: 100)
}

/// Usage of one CPU core.
struct CoreUsage: Identifiable, Sendable, Equatable {
    let id: Int
    let kind: CoreKind
    /// Busy percentage (user + system), 0–100.
    let usage: Double
}

/// Apple Silicon has two kinds of cores: Performance (fast) and Efficiency
/// (power-saving). Intel Macs only have one kind.
enum CoreKind: Sendable, Equatable {
    case performance, efficiency, standard

    var shortLabel: String {
        switch self {
        case .performance: "P"
        case .efficiency: "E"
        case .standard: "C"
        }
    }
}
