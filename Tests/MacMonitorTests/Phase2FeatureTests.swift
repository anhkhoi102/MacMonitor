import Foundation
import Testing
@testable import MacMonitor

struct ProcessMonitorTests {
    /// M1: one mach tick = 125/3 ns.
    let tick = 125.0 / 3.0 / 1_000_000_000

    @Test func cpuPercentIsShareOfTotalCapacity() {
        // 1 s of CPU time used during a 2 s window on an 8-core Mac:
        let oneSecondOfTicks = UInt64((1 / tick).rounded())
        let cpu = ProcessMonitorService.cpuPercent(deltaTicks: oneSecondOfTicks, ticksToSeconds: tick,
                                                   elapsedSeconds: 2, cores: 8)
        #expect(abs(cpu.ofOneCore - 50) < 0.01)    // Activity Monitor style
        #expect(abs(cpu.ofAll - 6.25) < 0.01)      // share of all 8 cores
    }

    @Test func cpuPercentNeverExceeds100OfTotal() {
        let lots = UInt64((100 / tick).rounded())
        #expect(ProcessMonitorService.cpuPercent(deltaTicks: lots, ticksToSeconds: tick, elapsedSeconds: 1, cores: 8).ofAll == 100)
        #expect(ProcessMonitorService.cpuPercent(deltaTicks: 5, ticksToSeconds: tick, elapsedSeconds: 0, cores: 8).ofAll == 0)
    }

    @Test func namesComeFromTheInnermostApp() {
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/X.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        #expect(ProcessMonitorService.displayName(path: helper, fallback: "").name == "Google Chrome Helper (Renderer)")
        #expect(ProcessMonitorService.displayName(path: "/Applications/Safari.app/Contents/MacOS/Safari", fallback: "").bundle
                == "/Applications/Safari.app")
        #expect(ProcessMonitorService.displayName(path: "/usr/libexec/trustd", fallback: "").name == "trustd")
        #expect(ProcessMonitorService.displayName(path: "", fallback: "mystery").name == "mystery")
    }

    @Test func liveSampleMeasuresThisTestProcess() async throws {
        let monitor = ProcessMonitorService()
        let first = await monitor.sample()
        let me = try #require(first.entries.first { $0.pid == getpid() })
        #expect(me.cpuPercent == nil)              // no previous reading yet
        #expect(me.memoryBytes > 0)
        #expect(me.memoryPercent > 0 && me.memoryPercent < 100)

        var x = 0.0
        for i in 0..<5_000_000 { x += Double(i).squareRoot() }   // burn some CPU
        let second = await monitor.sample()
        let again = try #require(second.entries.first { $0.pid == getpid() })
        #expect((again.cpuPercent ?? 0) > 0 || x < 0)
        #expect(second.restrictedCount > 0)        // system processes aren't readable
    }
}

@MainActor
struct ProcessTerminatorTests {
    @Test func criticalAndSystemProcessesAreProtected() {
        #expect(ProcessTerminator.protectionReason(pid: 1, name: "launchd", path: "/sbin/launchd") != nil)
        #expect(ProcessTerminator.protectionReason(pid: 500, name: "WindowServer", path: "/System/Library/X/WindowServer") != nil)
        #expect(ProcessTerminator.protectionReason(pid: 500, name: "trustd", path: "/usr/libexec/trustd") != nil)
        #expect(ProcessTerminator.protectionReason(pid: getpid(), name: "MacMonitor", path: "/Applications/MacMonitor.app/Contents/MacOS/MacMonitor") != nil)
    }

    @Test func appsAndUserProgramsMayBeEnded() {
        #expect(ProcessTerminator.protectionReason(pid: 500, name: "Notes", path: "/System/Applications/Notes.app/Contents/MacOS/Notes") == nil)
        #expect(ProcessTerminator.protectionReason(pid: 500, name: "Telegram", path: "/Applications/Telegram.app/Contents/MacOS/Telegram") == nil)
        #expect(ProcessTerminator.protectionReason(pid: 500, name: "node", path: "/opt/homebrew/bin/node") == nil)
    }

    /// Starts a real child process and ends it gracefully (SIGTERM).
    @Test func gracefulEndStopsANormalProcess() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["60"]
        try child.run()
        let outcome = await ProcessTerminator.endGracefully(pid: child.processIdentifier)
        #expect(outcome == .ended)
        child.waitUntilExit()
        #expect(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGTERM)
    }

    /// A process that ignores the polite request: the graceful step reports
    /// "still running", and only the separate force step ends it.
    @Test func forceEndOnlyAfterGracefulFails() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        child.arguments = ["-e", "$SIG{TERM}='IGNORE'; sleep 60"]
        try child.run()
        try await Task.sleep(for: .milliseconds(300))   // let perl install its handler
        #expect(await ProcessTerminator.endGracefully(pid: child.processIdentifier) == .stillRunning)
        #expect(ProcessTerminator.isRunning(child.processIdentifier))
        #expect(await ProcessTerminator.forceEnd(pid: child.processIdentifier) == .ended)
        child.waitUntilExit()
    }

    /// A reused PID must not be mistaken for the process the user picked.
    @MainActor @Test func recognizesOnlyTheSameProcess() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["60"]
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }
        let pid = child.processIdentifier
        func entry(path: String, start: Date?) -> ProcessEntry {
            ProcessEntry(pid: pid, name: "sleep", path: path, bundlePath: nil, cpuPercent: nil, cpuPercentOfOneCore: nil,
                         memoryBytes: 0, memoryPercent: 0, status: .running, startDate: start)
        }
        let path = ProcessMonitorService.path(of: pid)
        let start = ProcessMonitorService.startDate(of: pid)
        #expect(ProcessTerminator.isSameProcess(entry(path: path, start: start)))
        #expect(!ProcessTerminator.isSameProcess(entry(path: path, start: start?.addingTimeInterval(-5))))   // older process, same PID
        #expect(!ProcessTerminator.isSameProcess(entry(path: "/usr/bin/other", start: start)))
    }

    @Test func endingAnotherUsersProcessIsRefusedNotForced() async {
        // launchd's helper processes run as root; kill() is refused by macOS.
        let outcome = await ProcessTerminator.endGracefully(pid: 1)
        guard case .refused(let message) = outcome else { Issue.record("expected refusal, got \(outcome)"); return }
        #expect(message.contains("doesn't allow"))
    }
}

struct SystemUptimeTests {
    @Test func formatsDaysHoursMinutes() {
        let boot = Date(timeIntervalSince1970: 1_000_000)
        let now = boot.addingTimeInterval(2 * 86_400 + 5 * 3_600 + 32 * 60 + 15)
        #expect(SystemUptimeService.formatUptime(from: boot, to: now, locale: Locale(identifier: "en_US"))
                == "2 days, 5 hours, 32 minutes")
        #expect(SystemUptimeService.formatUptime(from: boot, to: boot.addingTimeInterval(3_660), locale: Locale(identifier: "en_US"))
                == "1 hour, 1 minute")
    }

    @Test func bootTimeIsRealAndInThePast() throws {
        let boot = try #require(SystemUptimeService.bootDate())
        #expect(boot < Date())
        #expect(boot > Date(timeIntervalSince1970: 1_577_836_800))   // after 2020
    }
}

struct NetworkInfoTests {
    @Test func parsesCloudflareTrace() {
        let trace = "fl=1\nh=1.1.1.1\nip=203.0.113.10\nts=1\nloc=VN\n"
        #expect(NetworkInfoService.parseTrace(trace) == "203.0.113.10")
        #expect(NetworkInfoService.parseTrace("ip=2001:db8::1\n") == nil)   // IPv6 is not IPv4
        #expect(NetworkInfoService.parseTrace("ip=<html>\n") == nil)
        #expect(NetworkInfoService.parseTrace("nothing here") == nil)
    }

    @Test func picksTheActiveInterfaceNotTheFirst() {
        typealias A = NetworkInfoService.InterfaceAddress
        let all = [A(interface: "utun4", address: "10.8.0.2"), A(interface: "en0", address: "192.168.1.100"),
                   A(interface: "en7", address: "192.168.2.5")]
        let split = NetworkInfoService.split(all, primaryInterface: "en0")
        #expect(split.primary?.address == "192.168.1.100")
        #expect(split.others.map(\.interface) == ["utun4", "en7"])
        #expect(split.others.first?.kind == "VPN")
        #expect(NetworkInfoService.split(all, primaryInterface: nil).primary == nil)
    }
}

struct CPUTemperatureTests {
    @Test func neverReportsAGuessedValue() {
        guard case .unavailable = CPUTemperatureService.read() else {
            Issue.record("A temperature must only be shown if it comes from a reliable source")
            return
        }
    }
}

/// The Processes list must show the busiest processes first by default.
struct ProcessSortTests {
    @Test func defaultSortIsLargestFirst() {
        func entry(_ pid: pid_t, cpu: Double?, mem: UInt64) -> ProcessEntry {
            ProcessEntry(pid: pid, name: "p\(pid)", path: "", bundlePath: nil, cpuPercent: cpu, cpuPercentOfOneCore: cpu,
                         memoryBytes: mem, memoryPercent: 0, status: .running, startDate: nil)
        }
        // Mirrors ProcessesView: sort ascending, then reverse for "largest first".
        let entries = [entry(1, cpu: 0.1, mem: 5), entry(2, cpu: 9.0, mem: 1), entry(3, cpu: nil, mem: 9)]
        let byCPU = Array(entries.sorted { ($0.cpuForSorting, $0.memoryBytes) < ($1.cpuForSorting, $1.memoryBytes) }.reversed())
        #expect(byCPU.map(\.pid) == [2, 1, 3])   // nil CPU (first sample) goes last
        let byMemory = Array(entries.sorted { $0.memoryBytes < $1.memoryBytes }.reversed())
        #expect(byMemory.map(\.pid) == [3, 1, 2])
    }
}
