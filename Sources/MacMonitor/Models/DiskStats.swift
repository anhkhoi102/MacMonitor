import Foundation

/// Capacity of a storage volume, in bytes.
struct DiskStats: Sendable, Equatable {
    var volumeName: String
    var total: UInt64
    /// What Finder calls "Available": free space + purgeable space
    /// (caches and snapshots macOS deletes automatically when space is needed).
    var available: UInt64
    /// Space that is free right now, without purging anything (what `df` shows).
    var free: UInt64 = 0

    var used: UInt64 { total > available ? total - available : 0 }
    var purgeable: UInt64 { available > free ? available - free : 0 }
    var utilization: Double { total == 0 ? 0 : Double(used) / Double(total) * 100 }

    static let zero = DiskStats(volumeName: "—", total: 0, available: 0)
}
