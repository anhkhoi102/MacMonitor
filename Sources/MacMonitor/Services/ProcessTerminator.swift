import AppKit
import Darwin

/// Ends processes the user chose, safely (Process Monitor › End Process).
///
/// 1. **Refuses** critical macOS processes, other users' processes and
///    MacMonitor itself (see `protectionReason`).
/// 2. **Graceful first:** apps get a normal Quit request through
///    `NSRunningApplication.terminate()` – the same as choosing Quit, so the
///    app can ask to save your work. Other processes get `SIGTERM`, the
///    standard "please exit" signal, via the `kill` system call.
/// 3. Waits up to 5 seconds. If it's still running, the UI may offer
///    **Force Quit** (`forceTerminate()` / `SIGKILL`) with a clear warning that
///    unsaved work is lost.
///
/// It never uses `sudo`, shell commands or admin rights; if macOS refuses
/// (EPERM), it says so.
@MainActor
enum ProcessTerminator {
    enum Outcome: Equatable {
        case ended
        case stillRunning
        case alreadyGone
        case refused(String)
    }

    /// Programs that must never be ended from here, whoever owns them.
    static let criticalNames: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow", "SystemUIServer", "Dock",
        "ControlCenter", "NotificationCenter", "coreaudiod", "cfprefsd", "distnoted",
        "UserEventAgent", "tccd", "securityd", "trustd", "opendirectoryd", "mds", "mds_stores",
    ]

    /// Why a process may not be ended, or nil if it may.
    static func protectionReason(pid: pid_t, name: String, path: String,
                                 ownPID: pid_t = getpid()) -> String? {
        if pid <= 1 { return "This is a core part of macOS." }
        if pid == ownPID { return "This is MacMonitor itself. Use MacMonitor › Quit instead." }
        if criticalNames.contains(name) || criticalNames.contains((path as NSString).lastPathComponent) {
            return "\(name) is essential to macOS. Ending it could log you out or freeze the Mac."
        }
        // Apps (including Apple's own, like Safari or Notes) may be quit.
        let isApp = path.contains(".app/") && path.contains("/Applications/")
        let systemPrefixes = ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/"]
        if !isApp, systemPrefixes.contains(where: { path.hasPrefix($0) }) {
            return "\(name) is a macOS system process. macOS restarts or relies on it, so MacMonitor won't end it."
        }
        return nil
    }

    /// Process IDs are reused: if the listed process has exited since the
    /// list was refreshed, its PID may now belong to a different program.
    /// Returns true only if the PID still runs the same program, started at
    /// the same moment, so a signal never reaches the wrong process.
    static func isSameProcess(_ entry: ProcessEntry) -> Bool {
        guard isRunning(entry.pid) else { return false }
        if let listed = entry.startDate {
            guard let current = ProcessMonitorService.startDate(of: entry.pid),
                  abs(current.timeIntervalSince(listed)) < 0.001 else { return false }
        }
        return entry.path.isEmpty || ProcessMonitorService.path(of: entry.pid) == entry.path
    }

    /// Step 2: ask nicely, then wait up to 5 s.
    static func endGracefully(pid: pid_t) async -> Outcome {
        if let app = NSRunningApplication(processIdentifier: pid) {
            guard app.terminate() else {
                return isRunning(pid) ? .refused("macOS didn't deliver the Quit request.") : .alreadyGone
            }
        } else {
            if let failure = send(SIGTERM, to: pid) { return failure }
        }
        return await waitForExit(pid)
    }

    /// Step 3, only after the user confirms: ends it immediately.
    static func forceEnd(pid: pid_t) async -> Outcome {
        if let app = NSRunningApplication(processIdentifier: pid) {
            _ = app.forceTerminate()
        } else if let failure = send(SIGKILL, to: pid) {
            return failure
        }
        return await waitForExit(pid, seconds: 2)
    }

    // MARK: Helpers

    private static func send(_ signal: Int32, to pid: pid_t) -> Outcome? {
        guard kill(pid, signal) != 0 else { return nil }
        switch errno {
        case ESRCH: return .alreadyGone
        case EPERM: return .refused("macOS doesn't allow MacMonitor to end this process. It belongs to the system or another user.")
        default: return .refused(String(cString: strerror(errno)))
        }
    }

    private static func waitForExit(_ pid: pid_t, seconds: Double = 5) async -> Outcome {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if !isRunning(pid) { return .ended }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return isRunning(pid) ? .stillRunning : .ended
    }

    /// `kill(pid, 0)` sends nothing; it only checks whether the process exists.
    static func isRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
