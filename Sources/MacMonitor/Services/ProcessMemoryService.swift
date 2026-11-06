import Darwin
import Foundation

/// Measures memory used by each running app.
///
/// ## How it works
/// 1. `proc_listallpids` lists the ID of every running process.
/// 2. For each one, `proc_pid_rusage` returns its *physical footprint*: the
///    memory it is responsible for, including its compressed and swapped-out
///    pages. Activity Monitor's "Memory" column shows the same number.
/// 3. `proc_pidpath` gives the program's file path. Processes inside the same
///    `.app` bundle are added together, so Chrome's dozens of helper processes
///    show up as a single "Google Chrome" row, like Activity Monitor's app view.
///
/// ## Limits (no admin rights)
/// macOS only lets a normal app read processes owned by the same user.
/// System processes (WindowServer, kernel_task, root daemons) are counted
/// as "restricted" instead of shown. We never ask for administrator access.
///
/// Because footprint includes compressed and swapped memory, the total of all
/// apps can be larger than "Used" or even than physical RAM. That is expected.
///
/// A full scan of ~570 processes takes about 4 ms, done on a background thread.
/// It only runs while the Memory page is open.
enum ProcessMemoryService {
    /// One process as read from the kernel.
    struct ProcessSample: Sendable, Equatable {
        let pid: pid_t
        let path: String
        let name: String
        let footprint: UInt64
    }

    @concurrent
    static func sample() async -> AppMemoryReport {
        let (processes, restricted) = readProcesses()
        return AppMemoryReport(apps: group(processes),
                               readableProcessCount: processes.count,
                               restrictedProcessCount: restricted)
    }

    // MARK: - Pure logic (unit-tested)

    /// Adds up processes that belong to the same app, largest first.
    static func group(_ processes: [ProcessSample]) -> [AppMemoryUsage] {
        var groups: [String: (name: String, bundle: String?, bytes: UInt64, count: Int)] = [:]
        for process in processes {
            let (key, name, bundle) = appGroup(forPath: process.path, fallbackName: process.name)
            var entry = groups[key] ?? (name, bundle, 0, 0)
            entry.bytes += process.footprint
            entry.count += 1
            groups[key] = entry
        }
        return groups
            .map { AppMemoryUsage(id: $0.key, name: $0.value.name, bundlePath: $0.value.bundle,
                                  footprint: $0.value.bytes, processCount: $0.value.count) }
            .sorted { $0.footprint != $1.footprint ? $0.footprint > $1.footprint : $0.name < $1.name }
    }

    /// Works out which app a process belongs to from its path.
    ///
    /// The *outermost* ".app/" wins, so
    /// `/Applications/Google Chrome.app/…/Google Chrome Helper.app/…/Helper`
    /// belongs to "Google Chrome".
    static func appGroup(forPath path: String, fallbackName: String)
        -> (key: String, name: String, bundlePath: String?)
    {
        if let range = path.range(of: ".app/") {
            let bundle = String(path[..<range.lowerBound]) + ".app"
            let name = ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
            return (bundle, name, bundle)
        }
        if !path.isEmpty {
            return (path, (path as NSString).lastPathComponent, nil)
        }
        let name = fallbackName.isEmpty ? "Unknown" : fallbackName
        return ("name:" + name, name, nil)
    }

    // MARK: - Kernel calls

    private static func readProcesses() -> (readable: [ProcessSample], restricted: Int) {
        // Ask once with a generous buffer; there are usually 400–800 processes.
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return ([], 0) }

        var readable: [ProcessSample] = []
        readable.reserveCapacity(count)
        var restricted = 0
        var pathBuffer = [UInt8](repeating: 0, count: 4096)   // PROC_PIDPATHINFO_MAXSIZE
        var nameBuffer = [UInt8](repeating: 0, count: 256)

        for pid in pids.prefix(count) where pid > 0 {
            var info = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard result == 0 else {
                restricted += 1   // usually "permission denied": another user's process
                continue
            }

            let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            let path = pathLength > 0 ? String(decoding: pathBuffer.prefix(Int(pathLength)), as: UTF8.self) : ""
            let nameLength = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
            let name = nameLength > 0 ? String(decoding: nameBuffer.prefix(Int(nameLength)), as: UTF8.self) : ""

            readable.append(ProcessSample(pid: pid, path: path, name: name, footprint: info.ri_phys_footprint))
        }
        return (readable, restricted)
    }
}
