import Testing
@testable import MacMonitor

/// Tests for the memory maths, using made-up page counts so results are exact.
struct MemoryServiceTests {
    typealias Pages = MemoryService.PageCounts
    let pageSize: UInt64 = 16_384
    let gib: UInt64 = 1_073_741_824

    @Test func followsActivityMonitorFormulas() {
        let pages = Pages(free: 1_000, anonymous: 100_000, fileBacked: 50_000,
                          purgeable: 2_000, wired: 60_000, compressor: 20_000)
        let stats = MemoryService.makeStats(pages: pages, pageSize: pageSize, totalBytes: 8 * gib,
                                            pressureLevel: 1, availablePercent: 70,
                                            swapUsed: 0, swapTotal: 0)

        #expect(stats.appMemory == 98_000 * pageSize)          // anonymous − purgeable
        #expect(stats.wired == 60_000 * pageSize)
        #expect(stats.compressed == 20_000 * pageSize)
        #expect(stats.cached == 52_000 * pageSize)             // file-backed + purgeable
        #expect(stats.used == (98_000 + 60_000 + 20_000) * pageSize)
        #expect(stats.available == 8 * gib - stats.used)
    }

    @Test func usedIsNotTotalMinusFree() {
        // Almost no "free" pages, but lots of droppable cache:
        // the Mac is NOT nearly full, and we must not report it as such.
        let pages = Pages(free: 10, anonymous: 100_000, fileBacked: 300_000,
                          purgeable: 0, wired: 50_000, compressor: 0)
        let stats = MemoryService.makeStats(pages: pages, pageSize: pageSize, totalBytes: 8 * gib,
                                            pressureLevel: 1, availablePercent: 80,
                                            swapUsed: 0, swapTotal: 0)

        let naiveUsed = 8 * gib - 10 * pageSize
        #expect(stats.used < naiveUsed / 2)
        #expect(stats.utilization < 30)
    }

    @Test(arguments: [(1, MemoryPressure.normal), (2, .warning), (4, .critical), (99, .normal)])
    func mapsKernelPressureLevels(level: Int, expected: MemoryPressure) {
        let stats = MemoryService.makeStats(pages: emptyPages, pageSize: pageSize, totalBytes: 8 * gib,
                                            pressureLevel: level, availablePercent: 50,
                                            swapUsed: 0, swapTotal: 0)
        #expect(stats.pressure == expected)
    }

    @Test func pressureGaugeIsInverseOfAvailablePercent() {
        let stats = MemoryService.makeStats(pages: emptyPages, pageSize: pageSize, totalBytes: 8 * gib,
                                            pressureLevel: 2, availablePercent: 37,
                                            swapUsed: 0, swapTotal: 0)
        #expect(stats.pressurePercent == 63)
    }

    @Test func purgeableLargerThanAnonymousDoesNotUnderflow() {
        let pages = Pages(free: 0, anonymous: 10, fileBacked: 0, purgeable: 20, wired: 0, compressor: 0)
        let stats = MemoryService.makeStats(pages: pages, pageSize: pageSize, totalBytes: 8 * gib,
                                            pressureLevel: 1, availablePercent: nil,
                                            swapUsed: 0, swapTotal: 0)
        #expect(stats.appMemory == 0)
    }

    @Test func liveSampleIsPlausible() throws {
        let sample = MemoryService().sample()
        let stats = try #require(sample)

        #expect(stats.total > 0)
        #expect(stats.used > 0 && stats.used <= stats.total)
        #expect((0...100).contains(stats.pressurePercent))
        #expect(stats.swapUsed <= stats.swapTotal)
    }

    private var emptyPages: Pages {
        Pages(free: 0, anonymous: 0, fileBacked: 0, purgeable: 0, wired: 0, compressor: 0)
    }
}
