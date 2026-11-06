import Foundation

/// One running process, as shown in the Process Monitor.
struct ProcessEntry: Identifiable, Sendable, Equatable {
    let pid: pid_t
    var id: pid_t { pid }
    /// App name (e.g. "Safari") or process name (e.g. "trustd").
    let name: String
    /// Full path of the program file ("" if macOS doesn't say).
    let path: String
    /// The .app bundle this process's program lives in (for its icon).
    let bundlePath: String?
    /// CPU use as a share of the Mac's *total* CPU capacity: all cores busy
    /// = 100%. Like Windows Task Manager. nil on the first sample (no
    /// previous reading to compare with yet).
    let cpuPercent: Double?
    /// The same, as Activity Monitor shows it: 100% = one full core.
    let cpuPercentOfOneCore: Double?
    /// Physical footprint (= Activity Monitor's Memory column), bytes.
    let memoryBytes: UInt64
    /// Share of the Mac's physical RAM.
    let memoryPercent: Double
    let status: ProcessStatus
    let startDate: Date?

    /// Sorting helpers (Table needs non-optional values).
    var cpuForSorting: Double { cpuPercent ?? -1 }
    var memoryForSorting: UInt64 { memoryBytes }
    var pidForSorting: Int { Int(pid) }
}

/// The process state macOS reports (BSD `pbi_status`).
///
/// macOS has no public API for Activity Monitor's "Not Responding" (that
/// comes from the window server's private interfaces), so it isn't shown.
enum ProcessStatus: Sendable, Equatable {
    case running, sleeping, stopped, zombie, unknown

    init(bsdStatus: UInt32) {
        switch Int32(bsdStatus) {
        case SRUN, SIDL: self = .running
        case SSLEEP: self = .sleeping
        case SSTOP: self = .stopped
        case SZOMB: self = .zombie
        default: self = .unknown
        }
    }

    var title: String {
        switch self {
        case .running: "Running"
        case .sleeping: "Sleeping"
        case .stopped: "Stopped"
        case .zombie: "Exiting"
        case .unknown: "—"
        }
    }
}

/// Result of one scan of running processes.
struct ProcessSnapshot: Sendable, Equatable {
    var entries: [ProcessEntry]
    /// Processes owned by macOS or other users. Their CPU and memory can't be
    /// read without administrator rights, so they're counted, not listed.
    var restrictedCount: Int
    var date: Date
}

/// How the process list is sorted.
enum ProcessSortKey: String, CaseIterable, Identifiable, Sendable {
    case cpu, memory
    var id: String { rawValue }
    var title: String { self == .cpu ? "CPU" : "Memory" }
}
