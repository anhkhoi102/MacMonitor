import Foundation

/// Memory used by one app (all of its processes added together).
struct AppMemoryUsage: Identifiable, Sendable, Equatable {
    /// Grouping key: the .app bundle path, or the executable path for
    /// processes that are not part of an app.
    let id: String
    let name: String
    /// Path of the .app bundle, used to show its icon. nil for command-line
    /// tools and background daemons.
    let bundlePath: String?
    /// Sum of the "physical footprint" of every process in the group – the
    /// same number as Activity Monitor's "Memory" column.
    let footprint: UInt64
    let processCount: Int
}

/// Result of one scan of all running processes.
struct AppMemoryReport: Sendable, Equatable {
    /// Sorted largest first.
    var apps: [AppMemoryUsage]
    /// Processes we were allowed to read.
    var readableProcessCount: Int
    /// Processes owned by macOS or other users. macOS does not let a normal
    /// app read their memory, and we don't ask for admin rights.
    var restrictedProcessCount: Int

    var totalFootprint: UInt64 { apps.reduce(0) { $0 + $1.footprint } }

    static let empty = AppMemoryReport(apps: [], readableProcessCount: 0, restrictedProcessCount: 0)
}
