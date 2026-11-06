import Testing
@testable import MacMonitor

/// Tests for the CPU percentage maths. They feed made-up tick counters into
/// `CPUService.makeStats`, so the results are exact and repeatable.
struct CPUServiceTests {
    typealias Ticks = CPUService.Ticks

    @Test func computesPercentagesFromTickDeltas() {
        let before = [Ticks(user: 100, system: 50, idle: 800, nice: 0)]
        // +30 user, +10 system, +60 idle → 100 ticks elapsed.
        let after = [Ticks(user: 130, system: 60, idle: 860, nice: 0)]

        let stats = CPUService.makeStats(previous: before, current: after,
                                         efficiencyCoreCount: 0, performanceCoreCount: 0)

        #expect(stats.user == 30)
        #expect(stats.system == 10)
        #expect(stats.idle == 60)
        #expect(stats.total == 40)
    }

    @Test func countsNiceTimeAsUser() {
        let before = [Ticks(user: 0, system: 0, idle: 0, nice: 0)]
        let after = [Ticks(user: 10, system: 0, idle: 80, nice: 10)]

        let stats = CPUService.makeStats(previous: before, current: after,
                                         efficiencyCoreCount: 0, performanceCoreCount: 0)

        #expect(stats.user == 20)
        #expect(stats.idle == 80)
    }

    @Test func handlesCounterWrapAround() {
        // The 32-bit counter rolls over from near-max back to a small number.
        let before = [Ticks(user: UInt32.max - 9, system: 0, idle: 0, nice: 0)]
        let after = [Ticks(user: 10, system: 0, idle: 80, nice: 0)]   // +20 user, +80 idle

        let stats = CPUService.makeStats(previous: before, current: after,
                                         efficiencyCoreCount: 0, performanceCoreCount: 0)

        #expect(stats.user == 20)
        #expect(stats.idle == 80)
    }

    @Test func noElapsedTimeMeansIdleNotCrash() {
        let ticks = [Ticks(user: 5, system: 5, idle: 5, nice: 0)]
        let stats = CPUService.makeStats(previous: ticks, current: ticks,
                                         efficiencyCoreCount: 0, performanceCoreCount: 0)
        #expect(stats.total == 0)
        #expect(stats.idle == 100)
    }

    @Test func labelsEfficiencyCoresFirstOnAppleSilicon() {
        let zero = Ticks(user: 0, system: 0, idle: 0, nice: 0)
        let busy = Ticks(user: 100, system: 0, idle: 0, nice: 0)     // 100% busy
        let quiet = Ticks(user: 0, system: 0, idle: 100, nice: 0)    // 0% busy

        let stats = CPUService.makeStats(previous: [zero, zero, zero, zero],
                                         current: [quiet, quiet, busy, busy],
                                         efficiencyCoreCount: 2, performanceCoreCount: 2)

        #expect(stats.cores.map(\.kind) == [.efficiency, .efficiency, .performance, .performance])
        #expect(stats.cores.map(\.usage) == [0, 0, 100, 100])
        #expect(stats.total == 50)   // average across all cores
    }

    @Test func liveSampleIsWithinValidRange() async throws {
        var service = CPUService()
        try await Task.sleep(for: .milliseconds(200))
        let sample = service.sample()
        let stats = try #require(sample)

        #expect(!stats.cores.isEmpty)
        #expect((0...100).contains(stats.total))
        #expect(abs(stats.user + stats.system + stats.idle - 100) < 0.01)
        #expect(!service.processorName.isEmpty)
    }
}

struct HistoryTests {
    @Test func dropsOldestSamplesWhenFull() {
        var history = History()
        for value in 1...15 { history.append(Double(value), capacity: 10) }

        #expect(history.points.count == 10)
        #expect(history.points.first?.value == 6)
        #expect(history.points.last?.value == 15)
        #expect(history.capacity == 10)
    }
}
