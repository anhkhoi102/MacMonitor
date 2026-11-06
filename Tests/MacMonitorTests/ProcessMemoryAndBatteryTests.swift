import Foundation
import Testing
@testable import MacMonitor

struct ProcessMemoryServiceTests {
    typealias Sample = ProcessMemoryService.ProcessSample

    @Test func groupsHelperProcessesUnderOutermostApp() {
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        let group = ProcessMemoryService.appGroup(forPath: helper, fallbackName: "Google Chrome He")
        #expect(group.name == "Google Chrome")
        #expect(group.bundlePath == "/Applications/Google Chrome.app")
    }

    @Test func nonAppProcessesUseExecutableName() {
        let group = ProcessMemoryService.appGroup(forPath: "/usr/libexec/trustd", fallbackName: "trustd")
        #expect(group.name == "trustd")
        #expect(group.bundlePath == nil)
    }

    @Test func missingPathFallsBackToProcessName() {
        let group = ProcessMemoryService.appGroup(forPath: "", fallbackName: "mystery")
        #expect(group.name == "mystery")
    }

    @Test func sumsAndSortsByFootprint() {
        let mb: UInt64 = 1_048_576
        let samples = [
            Sample(pid: 1, path: "/Applications/Safari.app/Contents/MacOS/Safari", name: "Safari", footprint: 200 * mb),
            Sample(pid: 2, path: "/Applications/Safari.app/Contents/XPCServices/WebContent.xpc/Contents/MacOS/WebContent", name: "WebContent", footprint: 300 * mb),
            Sample(pid: 3, path: "/Applications/Notes.app/Contents/MacOS/Notes", name: "Notes", footprint: 400 * mb),
            Sample(pid: 4, path: "/usr/sbin/cfprefsd", name: "cfprefsd", footprint: 5 * mb),
        ]
        let apps = ProcessMemoryService.group(samples)

        #expect(apps.map(\.name) == ["Safari", "Notes", "cfprefsd"])
        #expect(apps[0].footprint == 500 * mb)
        #expect(apps[0].processCount == 2)
    }

    @Test func liveScanFindsThisTestProcess() async {
        let report = await ProcessMemoryService.sample()
        #expect(report.readableProcessCount > 0)
        #expect(report.totalFootprint > 0)
    }
}

struct MemoryByTypeTests {
    @Test func segmentsAddUpToTotal() {
        let gib: UInt64 = 1_073_741_824
        let stats = MemoryStats(total: 8 * gib, appMemory: 3 * gib, wired: gib, compressed: gib,
                                cached: 2 * gib, pressure: .normal, pressurePercent: 30, free: gib / 2)
        #expect(stats.other == gib / 2)
        #expect(stats.segments.reduce(0) { $0 + $1.bytes } == stats.total)
    }

    @Test func otherNeverGoesNegative() {
        // Counters read a split second apart can add up to slightly more than total.
        let stats = MemoryStats(total: 100, appMemory: 60, wired: 30, compressed: 10,
                                cached: 20, pressure: .normal, pressurePercent: 0, free: 5)
        #expect(stats.other == 0)
    }
}

struct BatteryServiceTests {
    /// Shaped like the real AppleSmartBattery data from a MacBook Air M1.
    let charging: [String: Any] = [
        "BatteryInstalled": true, "CurrentCapacity": 64, "MaxCapacity": 100,
        "ExternalConnected": true, "IsCharging": true, "FullyCharged": false,
        "TimeRemaining": 103, "CycleCount": 403, "Voltage": 12145, "InstantAmperage": 1442,
        "AdapterDetails": ["Watts": 25],
        "BatteryData": ["DesignCapacity": 4382, "NominalChargeCapacity": 3590, "FullChargeCapacity": 3460],
    ]

    @Test func parsesChargingBattery() throws {
        guard case .present(let b) = BatteryService.makeReading(from: charging) else {
            Issue.record("expected a battery"); return
        }
        #expect(b.percent == 64)
        #expect(b.state == .charging)
        #expect(b.minutesRemaining == 103)
        #expect(b.cycleCount == 403)
        #expect(b.adapterWatts == 25)
        #expect(abs(b.power - 17.51) < 0.01)                       // 12.145 V × 1.442 A
        #expect(abs(try #require(b.estimatedHealth) - 81.93) < 0.01)  // 3590 / 4382
    }

    @Test func dischargingCurrentStoredAsUnsignedBecomesNegative() {
        var p = charging
        p["IsCharging"] = false
        p["ExternalConnected"] = false
        p["InstantAmperage"] = NSNumber(value: UInt64(bitPattern: -800))   // −800 mA
        guard case .present(let b) = BatteryService.makeReading(from: p) else {
            Issue.record("expected a battery"); return
        }
        #expect(b.amperage == -0.8)
        #expect(b.power < 0)
        #expect(b.state == .onBattery)
    }

    @Test func calculatingTimeIsNil() {
        var p = charging
        p["TimeRemaining"] = 65535
        guard case .present(let b) = BatteryService.makeReading(from: p) else {
            Issue.record("expected a battery"); return
        }
        #expect(b.minutesRemaining == nil)
    }

    @Test func pluggedInButPaused() {
        var p = charging
        p["IsCharging"] = false
        guard case .present(let b) = BatteryService.makeReading(from: p) else {
            Issue.record("expected a battery"); return
        }
        #expect(b.state == .pluggedInNotCharging)
    }

    @Test func noBatteryInstalled() {
        #expect(BatteryService.makeReading(from: ["BatteryInstalled": false]) == .notInstalled)
        #expect(BatteryService.makeReading(from: [:]) == .unavailable)
    }
}
