import Darwin
import Foundation

/// Reads every running process's CPU and memory use (Process Monitor).
///
/// ## How CPU % is calculated
/// The kernel keeps, per process, the total CPU time it has used (user +
/// system), in "mach ticks". Each sample compares with the previous one:
///
///     CPU % of one core  = Δ CPU time ÷ Δ wall-clock time × 100
///     CPU % of total     = that ÷ number of cores   (all cores busy = 100%)
///
/// On Apple Silicon a tick is 125/3 ns (`mach_timebase_info`), so ticks are
/// converted to seconds first – verified against `getrusage`.
///
/// ## Memory %
/// Physical footprint (Activity Monitor's "Memory") ÷ installed RAM.
///
/// It's an `actor`: its state (the previous sample) is only touched by one
/// task at a time, and its work runs off the main thread. Sampling ~570
/// processes takes a few milliseconds.
actor ProcessMonitorService {
    /// Identifies one process *run*: macOS reuses PIDs, so the start time is
    /// part of the key – a new process with an old PID never inherits its CPU.
    private struct Key: Hashable { let pid: pid_t; let start: UInt64 }

    private var previousTicks: [Key: UInt64] = [:]
    private var previousTime: ContinuousClock.Instant?
    private let ticksToSeconds: Double
    private let coreCount: Int
    private let physicalMemory: UInt64

    init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        ticksToSeconds = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
        coreCount = max(1, Sysctl.int("hw.logicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount)
        physicalMemory = Sysctl.uint64("hw.memsize") ?? 1
    }

    func sample() -> ProcessSnapshot {
        let now = ContinuousClock.now
        let elapsed = previousTime.map { now - $0 }
        let seconds = elapsed.map { Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18 }
        previousTime = now

        var pids = [pid_t](repeating: 0, count: 4096)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var entries: [ProcessEntry] = []
        entries.reserveCapacity(max(count, 0))
        var restricted = 0
        var currentTicks: [Key: UInt64] = [:]

        for pid in pids.prefix(max(count, 0)) where pid > 0 {
            var usage = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            } == 0
            guard ok else { restricted += 1; continue }   // another user's or a system process

            let key = Key(pid: pid, start: usage.ri_proc_start_abstime)
            let ticks = usage.ri_user_time + usage.ri_system_time
            currentTicks[key] = ticks

            var cpu: (ofAll: Double, ofOneCore: Double)?
            if let seconds, let before = previousTicks[key] {
                cpu = Self.cpuPercent(deltaTicks: ticks >= before ? ticks - before : 0,
                                      ticksToSeconds: ticksToSeconds, elapsedSeconds: seconds, cores: coreCount)
            }

            let path = Self.path(of: pid)
            let (name, bundle) = Self.displayName(path: path, fallback: Self.shortName(of: pid))
            entries.append(ProcessEntry(
                pid: pid, name: name, path: path, bundlePath: bundle,
                cpuPercent: cpu?.ofAll, cpuPercentOfOneCore: cpu?.ofOneCore,
                memoryBytes: usage.ri_phys_footprint,
                memoryPercent: Double(usage.ri_phys_footprint) / Double(physicalMemory) * 100,
                status: Self.status(of: pid),
                startDate: Self.startDate(of: pid)))
        }
        previousTicks = currentTicks   // forget processes that have exited
        return ProcessSnapshot(entries: entries, restrictedCount: restricted, date: Date())
    }

    // MARK: - Pure helpers (unit-tested)

    static func cpuPercent(deltaTicks: UInt64, ticksToSeconds: Double, elapsedSeconds: Double,
                           cores: Int) -> (ofAll: Double, ofOneCore: Double) {
        guard elapsedSeconds > 0 else { return (0, 0) }
        let ofOneCore = Double(deltaTicks) * ticksToSeconds / elapsedSeconds * 100
        return (min(100, ofOneCore / Double(max(cores, 1))), ofOneCore)
    }

    /// Name to show, and the .app bundle (for the icon). A program directly
    /// inside "X.app/Contents/MacOS/" is called "X"; the innermost app wins,
    /// so Chrome's helpers keep their own names (like Activity Monitor).
    static func displayName(path: String, fallback: String) -> (name: String, bundle: String?) {
        if let range = path.range(of: ".app/Contents/MacOS/", options: .backwards) {
            let bundle = String(path[..<range.lowerBound]) + ".app"
            return (((bundle as NSString).lastPathComponent as NSString).deletingPathExtension, bundle)
        }
        if !path.isEmpty { return ((path as NSString).lastPathComponent, nil) }
        return (fallback.isEmpty ? "Unknown" : fallback, nil)
    }

    // MARK: - Kernel calls

    static func path(of pid: pid_t) -> String {
        var buffer = [UInt8](repeating: 0, count: 4096)   // PROC_PIDPATHINFO_MAXSIZE
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(decoding: buffer.prefix(Int(length)), as: UTF8.self) : ""
    }

    private static func shortName(of pid: pid_t) -> String {
        var buffer = [UInt8](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(decoding: buffer.prefix(Int(length)), as: UTF8.self) : ""
    }

    private static func bsdInfo(of pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    private static func status(of pid: pid_t) -> ProcessStatus {
        bsdInfo(of: pid).map { ProcessStatus(bsdStatus: $0.pbi_status) } ?? .unknown
    }

    static func startDate(of pid: pid_t) -> Date? {
        guard let info = bsdInfo(of: pid) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1e6)
    }
}
