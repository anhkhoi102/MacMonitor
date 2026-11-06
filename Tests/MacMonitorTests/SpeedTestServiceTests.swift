import Foundation
import Testing
@testable import MacMonitor

/// Speed-test maths. These tests never touch the network.
struct SpeedTestServiceTests {
    @Test func megabitsPerSecond() {
        // 12.5 MB in 1 s = 100 Mbps
        #expect(SpeedTestService.mbps(bytes: 12_500_000, seconds: 1) == 100)
        #expect(SpeedTestService.mbps(bytes: 1_000, seconds: 0) == 0)
    }

    @Test func transferSizeGrowsUntilTransfersTakeAboutASecond() {
        #expect(SpeedTestService.nextTransferSize(current: 100_000, lastSeconds: 0.01, max: 50_000_000) == 400_000)
        #expect(SpeedTestService.nextTransferSize(current: 40_000_000, lastSeconds: 0.5, max: 50_000_000) == 50_000_000)
        #expect(SpeedTestService.nextTransferSize(current: 6_400_000, lastSeconds: 1.2, max: 50_000_000) == 6_400_000)
    }

    @Test func pingIsMedianAndJitterIsAverageChange() {
        let samples: [Double] = [40, 44, 38, 50, 42]
        #expect(SpeedTestService.median(samples) == 42)
        // |44−40| + |38−44| + |50−38| + |42−50| = 4 + 6 + 12 + 8 = 30 → 30 / 4
        #expect(SpeedTestService.jitter(samples) == 7.5)
        #expect(SpeedTestService.jitter([40]) == 0)
        #expect(SpeedTestService.median([]) == 0)
    }

    @Test func ninetiethPercentile() {
        let values = (1...10).map(Double.init)
        #expect(abs(SpeedTestService.percentile(values, 0.9) - 9.1) < 0.0001)
        #expect(SpeedTestService.percentile([5], 0.9) == 5)
    }

    @Test func parsesCloudflareServerTiming() {
        #expect(SpeedTestService.serverProcessingMs("cfSpeedEdge;dur=2, cfSpeedWorker;dur=19") == 19)
        #expect(SpeedTestService.serverProcessingMs("cfRequestDuration;dur=12.5") == 12.5)
        // Unrelated entries (TCP stats) are ignored.
        #expect(SpeedTestService.serverProcessingMs(#"cfL4;desc="?rtt=23480""#) == 0)
        #expect(SpeedTestService.serverProcessingMs(nil) == 0)
    }

    @Test func readsDataCentreFromRayHeader() {
        #expect(SpeedTestService.coloCode(fromRay: "8f2b1c0a4f6eddc5-SJC") == "SJC")
        #expect(SpeedTestService.coloCode(fromRay: "garbage") == nil)
        #expect(SpeedTestService.coloCode(fromRay: nil) == nil)
        #expect(SpeedTestService.cityNames["SJC"] == "San Jose")
    }

    @Test func friendlyErrorMessages() {
        #expect(SpeedTestError(urlError: URLError(.notConnectedToInternet)) == .offline)
        #expect(SpeedTestError(urlError: URLError(.timedOut)) == .timedOut)
        #expect(SpeedTestError(urlError: URLError(.cannotFindHost)) == .cannotReachServer)
        #expect(SpeedTestError.offline.errorDescription?.contains("offline") == true)
    }

    @Test func resultSurvivesSaveAndLoad() throws {
        let result = SpeedTestResult(downloadMbps: 95.2, uploadMbps: 40.1, pingMs: 38, jitterMs: 2.5,
                                     serverCode: "SJC", serverCity: "San Jose",
                                     date: Date(timeIntervalSince1970: 1_800_000_000), bytesTransferred: 1_000)
        let decoded = try JSONDecoder().decode(SpeedTestResult.self, from: JSONEncoder().encode(result))
        #expect(decoded == result)
        #expect(result.serverDescription == "Cloudflare · San Jose (SJC)")
    }
}

struct UploadTimingTests {
    @Test func usesServerReceiveTimeWhenAvailable() {
        // Measured with curl: 10 MB, cfSpeedWorker;dur=788 → ~101 Mbps.
        let seconds = SpeedTestService.uploadSeconds(serverMs: 788, roundTripSeconds: 0.84, pingMs: 43)
        #expect(seconds == 0.788)
        #expect(abs(SpeedTestService.mbps(bytes: 10_000_000, seconds: seconds) - 101.5) < 0.1)
    }

    @Test func fallsBackToRoundTripMinusPing() {
        #expect(abs(SpeedTestService.uploadSeconds(serverMs: 0, roundTripSeconds: 1.043, pingMs: 43) - 1.0) < 0.0001)
    }
}
