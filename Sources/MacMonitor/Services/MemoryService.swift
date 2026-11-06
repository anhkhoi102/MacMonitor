import Darwin

/// Reads real memory statistics from the macOS kernel (Phase 4).
///
/// ## Where the numbers come from
/// RAM is managed in fixed-size *pages* (16 KB on Apple Silicon). The kernel
/// counts how many pages are in each state; `host_statistics64(HOST_VM_INFO64)`
/// returns those counts (the Terminal command `vm_stat` prints the same data).
/// We convert them the way Activity Monitor does:
///
///     App Memory   = anonymous (app-owned) pages − purgeable pages
///     Wired        = wired pages (kernel memory that can never be moved out)
///     Compressed   = pages occupied by the compressor
///     Cached Files = file-backed pages + purgeable pages (droppable at any time)
///     Free         = free pages
///     Used         = App Memory + Wired + Compressed
///
/// ## Utilization vs pressure
/// *Utilization* = Used ÷ Total. It is often high on a Mac, and that's fine.
/// *Pressure* = how hard macOS must work (compressing, swapping) to satisfy
/// demand. We read two kernel values (also used by the `memory_pressure` tool):
///   - `kern.memorystatus_vm_pressure_level`: 1 Normal, 2 Warning, 4 Critical
///   - `kern.memorystatus_level`: % of memory still available → gauge = 100 − that
///
/// Every call is cheap (microseconds), so this runs on the main actor.
struct MemoryService {
    /// Raw page counts from the kernel.
    struct PageCounts: Equatable, Sendable {
        var free: UInt64
        var anonymous: UInt64      // "internal" pages, owned by apps
        var fileBacked: UInt64     // "external" pages, copies of files on disk
        var purgeable: UInt64
        var wired: UInt64
        var compressor: UInt64     // physical pages used by the compressor
    }

    let totalBytes: UInt64
    let pageSize: UInt64
    private let host: host_t = mach_host_self()

    init() {
        totalBytes = Sysctl.uint64("hw.memsize") ?? 0
        pageSize = UInt64(Sysctl.int("hw.pagesize") ?? 16_384)
    }

    func sample() -> MemoryStats? {
        guard let pages = readPageCounts() else { return nil }
        let swap = Self.readSwapUsage()
        return Self.makeStats(pages: pages, pageSize: pageSize, totalBytes: totalBytes,
                              pressureLevel: Sysctl.int("kern.memorystatus_vm_pressure_level") ?? 1,
                              availablePercent: Sysctl.int("kern.memorystatus_level"),
                              swapUsed: swap.used, swapTotal: swap.total)
    }

    // MARK: - Pure calculation (unit-tested)

    static func makeStats(pages: PageCounts, pageSize: UInt64, totalBytes: UInt64,
                          pressureLevel: Int, availablePercent: Int?,
                          swapUsed: UInt64, swapTotal: UInt64) -> MemoryStats {
        // Purgeable pages are counted inside "anonymous"; guard against
        // the counts briefly disagreeing while the kernel updates them.
        let appPages = pages.anonymous > pages.purgeable ? pages.anonymous - pages.purgeable : 0

        let level: MemoryPressure = switch pressureLevel {
        case 4: .critical
        case 2: .warning
        default: .normal
        }

        // Fall back to utilization if the kernel value is unavailable.
        let used = (appPages + pages.wired + pages.compressor) * pageSize
        let pressurePercent: Double
        if let availablePercent, (0...100).contains(availablePercent) {
            pressurePercent = Double(100 - availablePercent)
        } else {
            pressurePercent = totalBytes > 0 ? Double(used) / Double(totalBytes) * 100 : 0
        }

        return MemoryStats(
            total: totalBytes,
            appMemory: appPages * pageSize,
            wired: pages.wired * pageSize,
            compressed: pages.compressor * pageSize,
            cached: (pages.fileBacked + pages.purgeable) * pageSize,
            pressure: level,
            pressurePercent: pressurePercent,
            swapUsed: swapUsed,
            swapTotal: swapTotal,
            free: pages.free * pageSize
        )
    }

    // MARK: - Kernel calls

    private func readPageCounts() -> PageCounts? {
        var info = vm_statistics64()
        // The API measures the struct size in 32-bit integers, not bytes.
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return PageCounts(free: UInt64(info.free_count),
                          anonymous: UInt64(info.internal_page_count),
                          fileBacked: UInt64(info.external_page_count),
                          purgeable: UInt64(info.purgeable_count),
                          wired: UInt64(info.wire_count),
                          compressor: UInt64(info.compressor_page_count))
    }

    /// Swap = memory pages written to the SSD when RAM runs short.
    /// Same data as `sysctl vm.swapusage`.
    private static func readSwapUsage() -> (used: UInt64, total: UInt64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (usage.xsu_used, usage.xsu_total)
    }
}
