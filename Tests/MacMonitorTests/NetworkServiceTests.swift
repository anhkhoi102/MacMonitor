import Testing
@testable import MacMonitor

struct NetworkServiceTests {
    typealias C = NetworkService.Counters

    @Test func computesSpeedFromCounterDifference() {
        let before = ["en0": C(received: 1_000_000, sent: 200_000)]
        let after = ["en0": C(received: 3_000_000, sent: 600_000)]   // +2 MB in, +400 KB out
        let d = NetworkService.delta(previous: before, current: after, seconds: 2)

        #expect(d.receivedBytes == 2_000_000)
        #expect(d.sentBytes == 400_000)
        #expect(d.downloadPerSecond == 1_000_000)
        #expect(d.uploadPerSecond == 200_000)
    }

    @Test func ignoresLoopbackVPNAndAirDrop() {
        let before = ["lo0": C(received: 0, sent: 0), "utun4": C(received: 0, sent: 0),
                      "awdl0": C(received: 0, sent: 0), "en0": C(received: 0, sent: 0)]
        let after = ["lo0": C(received: 9_999, sent: 9_999), "utun4": C(received: 5_000, sent: 5_000),
                     "awdl0": C(received: 7_000, sent: 7_000), "en0": C(received: 1_000, sent: 500)]
        let d = NetworkService.delta(previous: before, current: after, seconds: 1)

        #expect(d.receivedBytes == 1_000)
        #expect(d.sentBytes == 500)
    }

    @Test func sumsWiFiAndEthernet() {
        let before = ["en0": C(received: 0, sent: 0), "en5": C(received: 0, sent: 0)]
        let after = ["en0": C(received: 100, sent: 10), "en5": C(received: 300, sent: 30)]
        let d = NetworkService.delta(previous: before, current: after, seconds: 1)
        #expect(d.receivedBytes == 400)
        #expect(d.sentBytes == 40)
    }

    @Test func counterResetIsNotNegativeTraffic() {
        let before = ["en0": C(received: 5_000_000, sent: 5_000_000)]
        let after = ["en0": C(received: 100, sent: 100)]   // interface was reset
        let d = NetworkService.delta(previous: before, current: after, seconds: 1)
        #expect(d.receivedBytes == 0)
        #expect(d.downloadPerSecond == 0)
    }

    @Test func newInterfaceStartsCountingNextSample() {
        let d = NetworkService.delta(previous: [:], current: ["en7": C(received: 9_000_000_000, sent: 0)], seconds: 1)
        #expect(d.receivedBytes == 0)   // not 9 GB of "instant" traffic
    }

    @Test func zeroElapsedTimeDoesNotDivideByZero() {
        let d = NetworkService.delta(previous: ["en0": C(received: 0, sent: 0)],
                                     current: ["en0": C(received: 10, sent: 10)], seconds: 0)
        #expect(d.downloadPerSecond == 0)
    }

    @Test func liveCountersAre64Bit() {
        let counters = NetworkService.readCounters()
        #expect(!counters.isEmpty)
        #expect(counters["lo0"] != nil)   // every Mac has the loopback interface
    }
}

struct SpeedFormattingTests {
    @Test func megabytesPerSecond() {
        #expect(Fmt.speed(2_500_000, unit: .megabytesPerSecond) == "2.50 MB/s")
        #expect(Fmt.speed(12_000, unit: .megabytesPerSecond) == "12 KB/s")
        #expect(Fmt.speed(-5, unit: .megabytesPerSecond) == "0 KB/s")
    }

    @Test func megabitsPerSecond() {
        #expect(Fmt.speed(2_500_000, unit: .megabitsPerSecond) == "20.0 Mbps")
        #expect(Fmt.speed(12_000, unit: .megabitsPerSecond) == "96 kbps")
    }
}

/// macOS gives normal apps 32-bit counters that wrap every 4 GB.
struct CounterWrapTests {
    let wrap = NetworkService.wrapValue

    @Test func wrapIsCountedAsTraffic() {
        // 4 294 967 000 → 20 000 000 is +20 000 296 bytes, not a reset.
        let before = ["en0": NetworkService.Counters(received: wrap - 296, sent: 0)]
        let after = ["en0": NetworkService.Counters(received: 20_000_000, sent: 0)]
        let d = NetworkService.delta(previous: before, current: after, seconds: 1)
        #expect(d.receivedBytes == 20_000_296)
    }

    @Test func implausibleJumpIsTreatedAsReset() {
        // Wrapping here would mean ~4 GB in one second (> 10 Gbit/s): it's a reset.
        #expect(NetworkService.bytesBetween(100_000, 50, seconds: 1) == 0)
    }

    @Test func valuesAbove32BitsNeverWrap() {
        #expect(NetworkService.bytesBetween(wrap + 10, 5, seconds: 1) == 0)
    }
}
