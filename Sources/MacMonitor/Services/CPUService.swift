import Darwin
import Foundation

/// Reads real CPU usage from the macOS kernel (Phase 3).
///
/// ## How CPU usage is measured
/// The kernel keeps, for every core, four ever-increasing counters of "ticks"
/// (small slices of time): how long the core spent running user code, kernel
/// (system) code, low-priority "nice" code, and doing nothing (idle).
///
/// A single reading is useless on its own – the counters started at boot.
/// So we read them twice and look at the *difference*:
///
///     user% = Δuser / (Δuser + Δsystem + Δidle + Δnice) × 100
///
/// `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` returns these counters for
/// each core in one cheap system call (a few microseconds), which is why
/// polling it once per second costs essentially nothing.
///
/// This is a `struct` used only from the main actor. Each sample takes
/// microseconds, so moving it to a background thread would add complexity
/// without any benefit.
struct CPUService {
    /// Raw tick counters for one core.
    struct Ticks: Equatable, Sendable {
        var user: UInt32
        var system: UInt32
        var idle: UInt32
        var nice: UInt32
    }

    /// e.g. "Apple M1"
    let processorName: String
    let performanceCoreCount: Int
    let efficiencyCoreCount: Int

    private let host: host_t = mach_host_self()
    private var previous: [Ticks] = []

    // For measuring MacMonitor's own CPU use.
    private var previousOwnCPUTime = CPUService.ownProcessCPUSeconds()
    private var previousWallTime = ContinuousClock.now

    init() {
        processorName = Sysctl.string("machdep.cpu.brand_string") ?? "Unknown CPU"
        // perflevel0 = Performance cores, perflevel1 = Efficiency cores (Apple Silicon only).
        performanceCoreCount = Sysctl.int("hw.perflevel0.logicalcpu") ?? 0
        efficiencyCoreCount = Sysctl.int("hw.perflevel1.logicalcpu") ?? 0
        previous = Self.readCoreTicks(host) ?? []
    }

    /// Takes a new reading and returns usage since the previous call.
    /// Returns nil if the kernel call fails.
    mutating func sample() -> CPUStats? {
        guard let current = Self.readCoreTicks(host) else { return nil }
        defer { previous = current }
        guard previous.count == current.count else { return nil }
        return Self.makeStats(previous: previous, current: current,
                              efficiencyCoreCount: efficiencyCoreCount,
                              performanceCoreCount: performanceCoreCount)
    }

    /// CPU used by MacMonitor itself since the previous call, as a percentage
    /// of one core (the same convention as Activity Monitor's "% CPU" column).
    mutating func ownProcessUsage() -> Double {
        let now = ContinuousClock.now
        let cpu = Self.ownProcessCPUSeconds()
        let elapsed = now - previousWallTime
        let wallSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        defer { previousOwnCPUTime = cpu; previousWallTime = now }
        guard wallSeconds > 0 else { return 0 }
        return max(0, (cpu - previousOwnCPUTime) / wallSeconds * 100)
    }

    // MARK: - Pure calculation (unit-tested)

    /// Turns two readings into percentages. Has no side effects, so it can be
    /// tested with made-up numbers.
    static func makeStats(previous: [Ticks], current: [Ticks],
                          efficiencyCoreCount: Int, performanceCoreCount: Int) -> CPUStats {
        var sumUser = 0.0, sumSystem = 0.0, sumIdle = 0.0, sumNice = 0.0
        var cores: [CoreUsage] = []
        let hasCoreTypes = efficiencyCoreCount > 0 && performanceCoreCount > 0

        for (index, (old, new)) in zip(previous, current).enumerated() {
            // `&-` is "wrapping subtraction": the 32-bit counters roll over
            // to 0 after ~500 days of uptime; this still gives the right delta.
            let user = Double(new.user &- old.user)
            let system = Double(new.system &- old.system)
            let idle = Double(new.idle &- old.idle)
            let nice = Double(new.nice &- old.nice)
            sumUser += user; sumSystem += system; sumIdle += idle; sumNice += nice

            let total = user + system + idle + nice
            let busy = total > 0 ? (user + system + nice) / total * 100 : 0
            // On Apple Silicon the kernel lists Efficiency cores first.
            let kind: CoreKind = !hasCoreTypes ? .standard
                : (index < efficiencyCoreCount ? .efficiency : .performance)
            cores.append(CoreUsage(id: index, kind: kind, usage: busy))
        }

        let total = sumUser + sumSystem + sumIdle + sumNice
        guard total > 0 else { return CPUStats(user: 0, system: 0, idle: 100, cores: cores) }
        // "nice" is low-priority user code; Activity Monitor counts it as User.
        return CPUStats(user: (sumUser + sumNice) / total * 100,
                        system: sumSystem / total * 100,
                        idle: sumIdle / total * 100,
                        cores: cores)
    }

    // MARK: - Kernel calls

    private static func readCoreTicks(_ host: host_t) -> [Ticks]? {
        var coreCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &coreCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { return nil }

        // The kernel allocated `info` for us; we must give the memory back,
        // otherwise every sample would leak a little memory.
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        let statesPerCore = Int(CPU_STATE_MAX)
        return (0..<Int(coreCount)).map { core in
            let base = core * statesPerCore
            func ticks(_ state: Int32) -> UInt32 { UInt32(bitPattern: info[base + Int(state)]) }
            return Ticks(user: ticks(CPU_STATE_USER), system: ticks(CPU_STATE_SYSTEM),
                         idle: ticks(CPU_STATE_IDLE), nice: ticks(CPU_STATE_NICE))
        }
    }

    /// Total CPU time (user + system) this process has used since launch.
    private static func ownProcessCPUSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
}
