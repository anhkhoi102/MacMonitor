import Darwin
import Foundation

/// Which files are open in running programs right now ("skip files in use").
///
/// For every process we're allowed to inspect (your own – which is all that
/// matters, since we only clean your own files), we ask the kernel for its
/// list of open files (`proc_pidinfo(PROC_PIDLISTFDS)`), the full path of each
/// (`proc_pidfdinfo(PROC_PIDFDVNODEPATHINFO)`) and its working folder. The
/// `lsof` command does the same thing.
///
/// An item counts as "in use" if any open file is the item itself or lies
/// inside it. Example: Chrome keeps its cache index files open, so the Chrome
/// cache folder is skipped while Chrome is running.
///
/// Taken once per cleanup, just before the first item is touched.
struct OpenFilesSnapshot: Sendable {
    /// Open path → names of the programs that have it open.
    private(set) var openPaths: [String: Set<String>] = [:]

    static func capture() -> OpenFilesSnapshot {
        var snapshot = OpenFilesSnapshot()
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        for pid in pids.prefix(max(count, 0)) where pid > 0 {
            let name = processName(pid)
            for path in openFiles(of: pid) {
                snapshot.openPaths[path, default: []].insert(name)
            }
        }
        return snapshot
    }

    init(openPaths: [String: Set<String>] = [:]) {
        self.openPaths = openPaths
    }

    /// Names of programs using `path` or anything inside it (empty = not in use).
    func users(of path: String) -> [String] {
        let folderPrefix = path.hasSuffix("/") ? path : path + "/"
        var names = Set<String>()
        for (open, programs) in openPaths where open == path || open.hasPrefix(folderPrefix) {
            names.formUnion(programs)
        }
        return names.sorted()
    }

    // MARK: Kernel calls

    private static func openFiles(of pid: pid_t) -> [String] {
        var paths: [String] = []

        // Working folder ("current directory") of the process.
        var vnodeInfo = proc_vnodepathinfo()
        let vnodeSize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnodeInfo, vnodeSize) == vnodeSize {
            let cwd = string(from: &vnodeInfo.pvi_cdir.vip_path)
            if !cwd.isEmpty && cwd != "/" { paths.append(cwd) }
        }

        // Open file descriptors.
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return paths }   // not allowed (another user's process) or none
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.stride)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bytes)
        guard filled > 0 else { return paths }

        let infoSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        for fd in fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride)
        where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            if proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, infoSize) == infoSize {
                let path = string(from: &info.pvip.vip_path)
                if !path.isEmpty { paths.append(path) }
            }
        }
        return paths
    }

    private static func processName(_ pid: pid_t) -> String {
        var buffer = [UInt8](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(decoding: buffer.prefix(Int(length)), as: UTF8.self) : "process \(pid)"
    }

    /// Converts the kernel's fixed-size C character array into a String.
    private static func string<T>(from tuple: inout T) -> String {
        withUnsafeBytes(of: &tuple) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
