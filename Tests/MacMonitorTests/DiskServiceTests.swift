import Testing
@testable import MacMonitor

struct DiskServiceTests {
    let gb = 1_000_000_000

    @Test func usesFinderStyleAvailableIncludingPurgeable() throws {
        let stats = try #require(DiskService.makeStats(name: "Macintosh HD", total: 245 * gb,
                                                       free: 71 * gb, importantAvailable: Int64(77 * gb)))
        #expect(stats.available == UInt64(77 * gb))
        #expect(stats.free == UInt64(71 * gb))
        #expect(stats.purgeable == UInt64(6 * gb))
        #expect(stats.used == UInt64(168 * gb))
        #expect(abs(stats.utilization - 168.0 / 245.0 * 100) < 0.001)
    }

    @Test func fallsBackToFreeSpaceWhenFinderValueMissing() throws {
        let stats = try #require(DiskService.makeStats(name: nil, total: 100 * gb,
                                                       free: 40 * gb, importantAvailable: nil))
        #expect(stats.available == UInt64(40 * gb))
        #expect(stats.purgeable == 0)
        #expect(stats.volumeName == "Startup Disk")
    }

    @Test func ignoresNonsensicalFinderValue() throws {
        // Larger than the whole disk → ignore it.
        let stats = try #require(DiskService.makeStats(name: "X", total: 100 * gb,
                                                       free: 40 * gb, importantAvailable: Int64(500 * gb)))
        #expect(stats.available == UInt64(40 * gb))
    }

    @Test func missingTotalMeansNoData() {
        #expect(DiskService.makeStats(name: "X", total: nil, free: 1, importantAvailable: 1) == nil)
        #expect(DiskService.makeStats(name: "X", total: 0, free: 1, importantAvailable: 1) == nil)
    }

    @Test func liveSampleOfStartupDisk() async throws {
        let sample = await DiskService.sample()
        let stats = try #require(sample)
        #expect(stats.total > 0)
        #expect(stats.free <= stats.available)
        #expect(stats.available <= stats.total)
    }
}
