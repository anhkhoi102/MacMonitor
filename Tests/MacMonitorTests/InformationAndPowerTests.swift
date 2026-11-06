import Foundation
import Testing
@testable import MacMonitor

struct MacOSVersionTests {
    @Test func comparesVersionsNumerically() {
        #expect(MacOSUpdateService.isNewer("27.2", than: "27.0.1"))
        #expect(MacOSUpdateService.isNewer("27.10", than: "27.9"))     // not alphabetical
        #expect(!MacOSUpdateService.isNewer("27.0", than: "27.0.0"))
        #expect(!MacOSUpdateService.isNewer("26.7.2", than: "27.0.1"))
        #expect(MacOSUpdateService.major(of: "27.0.1") == 27)
    }
}

struct UpdateCatalogTests {
    /// Same shape as Apple's gdmf.apple.com/v2/pmv feed.
    let catalog = """
    {"PublicAssetSets":{"macOS":[
      {"ProductVersion":"27.2","Build":"26B123","PostingDate":"2026-11-05","SupportedDevices":["J313AP","J314sAP"]},
      {"ProductVersion":"27.3","Build":"26C1","PostingDate":"2026-12-01","SupportedDevices":["J999AP"]},
      {"ProductVersion":"26.7.2","Build":"25G332","PostingDate":"2026-11-05","SupportedDevices":["J313AP","Mac-ABC"]}
    ]}}
    """.data(using: .utf8)!

    @Test func distinguishesLatestReleasedFromLatestCompatible() throws {
        let (latest, compatible) = try MacOSUpdateService.parseCatalog(catalog, boardID: "J313AP")
        #expect(latest?.version == "27.3")          // newest from Apple, for some other Mac
        #expect(compatible?.version == "27.2")      // newest this Mac can actually install
        #expect(compatible?.build == "26B123")
        #expect(compatible?.postingDate != nil)
    }

    @Test func unsupportedMacGetsOnlyWhatSupportsIt() throws {
        let (_, compatible) = try MacOSUpdateService.parseCatalog(catalog, boardID: "Mac-ABC")
        #expect(compatible?.version == "26.7.2")
        let (_, none) = try MacOSUpdateService.parseCatalog(catalog, boardID: "UNKNOWN")
        #expect(none == nil)                        // never assume compatibility
    }

    @Test func badCatalogThrows() {
        #expect(throws: (any Error).self) { try MacOSUpdateService.parseCatalog(Data("{}".utf8), boardID: "J313AP") }
    }
}

struct SecuritySummaryTests {
    let index = """
    <table><tr><th>Name</th></tr>
    <tr><td><a href="https://support.apple.com/en-us/149521">macOS Golden Gate 27.2</a></td><td>macOS Golden Gate</td><td>26 Oct 2026</td></tr>
    <tr><td><a href="https://support.apple.com/en-us/149522">macOS Tahoe 26.7.2</a></td><td>macOS Tahoe</td><td>26 Oct 2026</td></tr>
    <tr><td>macOS Golden Gate 27.0.1This update has no published CVE entries.</td><td>Mac</td><td>28 Sep 2026</td></tr>
    <tr><td><a href="x">Safari 27.2</a></td><td>macOS</td><td>26 Oct 2026</td></tr>
    </table>
    """

    @Test func readsMacOSRowsAndReleaseNames() {
        let rows = MacOSUpdateService.parseSecurityIndex(index)
        #expect(rows.map(\.version) == ["27.2", "26.7.2", "27.0.1"])     // Safari row ignored
        #expect(rows.first?.url == "https://support.apple.com/en-us/149521")
        #expect(rows.last?.url == nil)
        let names = MacOSUpdateService.releaseNames(from: rows)
        #expect(names["27"] == "Golden Gate")
        #expect(names["26"] == "Tahoe")
    }

    @Test func keepsOnlyHTTPSAppleLinks() {
        #expect(MacOSUpdateService.trustedAppleLink("https://support.apple.com/en-us/149521") != nil)
        #expect(MacOSUpdateService.trustedAppleLink("http://support.apple.com/en-us/1") == nil)
        #expect(MacOSUpdateService.trustedAppleLink("https://apple.com.evil.example/x") == nil)
        #expect(MacOSUpdateService.trustedAppleLink("https://evilapple.com/x") == nil)
        #expect(MacOSUpdateService.trustedAppleLink("file:///etc/passwd") == nil)
        #expect(MacOSUpdateService.trustedAppleLink("/en-us/1") == nil)
    }

    let page = """
    <h3>Kernel</h3><p>Available for: macOS Golden Gate</p>
    <p>Impact: An app may be able to execute arbitrary code with kernel privileges</p>
    <p>Description: fixed.</p><p>CVE-2026-1001: researcher</p>
    <h3>WebKit</h3><p>Impact: Processing maliciously crafted web content may lead to arbitrary code execution. Apple is aware of a report that this issue may have been exploited.</p>
    <p>CVE-2026-1002: researcher</p>
    <h3>Photos</h3><p>Impact: An app may be able to access sensitive user data</p><p>CVE-2026-1003</p><p>CVE-2026-1004</p>
    <h3>ImageIO</h3><p>Impact: Processing a maliciously crafted image may lead to unexpected app termination</p><p>CVE-2026-1005</p>
    <h2>Additional recognition</h2><p>CVE-2026-9999 thanks</p>
    """

    @Test func groupsIssuesByImpact() {
        let base = SecurityRelease(title: "macOS Golden Gate 27.2", version: "27.2", releaseDate: "26 Oct 2026", url: nil,
                                   issueCount: 0, cveIDs: [], groups: [], exploitedInTheWild: false)
        let release = MacOSUpdateService.summarizeSecurityPage(page, base: base)
        #expect(release.issueCount == 4)
        #expect(release.cveIDs == ["CVE-2026-1001", "CVE-2026-1002", "CVE-2026-1003", "CVE-2026-1004", "CVE-2026-1005"])
        #expect(!release.cveIDs.contains("CVE-2026-9999"))    // credits section isn't a fix
        #expect(release.exploitedInTheWild)
        let byCategory = Dictionary(uniqueKeysWithValues: release.groups.map { ($0.category, $0) })
        #expect(byCategory[.privilegeEscalation]?.cveIDs == ["CVE-2026-1001"])
        #expect(byCategory[.exploited]?.cveIDs == ["CVE-2026-1002"])
        #expect(byCategory[.privacy]?.count == 1)
        #expect(byCategory[.crash]?.count == 1)
    }

    @Test func priorityRules() {
        func release(_ categories: [ImpactCategory], exploited: Bool = false) -> SecurityRelease {
            SecurityRelease(title: "", version: "27.2", releaseDate: "", url: nil, issueCount: categories.count, cveIDs: [],
                            groups: categories.map { ImpactGroup(category: $0, count: 1, example: "", cveIDs: []) },
                            exploitedInTheWild: exploited)
        }
        #expect(MacOSUpdateService.priority(for: [release([.crash], exploited: true)], updateAvailable: true) == .critical)
        #expect(MacOSUpdateService.priority(for: [release([.codeExecution, .privilegeEscalation])], updateAvailable: true) == .critical)
        #expect(MacOSUpdateService.priority(for: [release([.codeExecution])], updateAvailable: true) == .high)
        #expect(MacOSUpdateService.priority(for: [release([.crash, .privacy])], updateAvailable: true) == .medium)
        #expect(MacOSUpdateService.priority(for: [], updateAvailable: true) == .low)
        #expect(MacOSUpdateService.priority(for: [release([.codeExecution])], updateAvailable: false) == .low)
    }

    @Test func cacheIsOnlyFreshForSameMacAndVersion() {
        let info = MacOSUpdateInfo(latestReleased: nil, latestCompatible: nil, releaseNames: [:], securityReleases: [],
                                   fetchedAt: Date(), boardID: "J313AP", installedVersion: "27.0.1")
        #expect(MacOSUpdateService.isFresh(info, boardID: "J313AP", installedVersion: "27.0.1"))
        #expect(!MacOSUpdateService.isFresh(info, boardID: "J313AP", installedVersion: "27.2"))   // after updating
        #expect(!MacOSUpdateService.isFresh(info, boardID: "J313AP", installedVersion: "27.0.1",
                                             now: Date().addingTimeInterval(13 * 3600)))
    }
}

struct SystemInfoTests {
    @Test func readsThisMac() {
        let info = SystemInfoService.collect()
        #expect(info.modelIdentifier == Sysctl.string("hw.model"))
        #expect(!info.chip.isEmpty && info.chip != "—")
        #expect(info.memoryBytes > 0)
        #expect(info.totalCores > 0)
        #expect(!info.osBuild.isEmpty)
        #expect(info.kernelVersion.hasPrefix("Darwin "))
        if info.isAppleSilicon { #expect(info.boardID != nil) }   // needed for update compatibility
    }

    @Test func registryValuesDecodeStringsAndData() {
        #expect(SystemInfoService.value("MacBook Air") == "MacBook Air")
        #expect(SystemInfoService.value(Data("J313\0".utf8)) == "J313")
        #expect(SystemInfoService.value(Data()) == nil)
        #expect(SystemInfoService.value(42) == nil)
    }
}

@MainActor
struct PowerServiceTests {
    @Test func actionsAndConfirmations() {
        #expect(PowerService.Action.restart.needsConfirmation)
        #expect(PowerService.Action.shutDown.needsConfirmation)
        #expect(!PowerService.Action.sleep.needsConfirmation)
        #expect(!PowerService.Action.lock.needsConfirmation)
    }

    /// Only checks that the lock function can be found – never calls it.
    @Test func lockFunctionIsFoundOnThisMac() {
        #expect(PowerService.isLockAvailable)
    }

    @Test func automationErrorsAreExplained() {
        #expect(PowerService.message(forAppleEventError: -1743).contains("Automation"))
        #expect(PowerService.message(forAppleEventError: -600).contains("login window"))
    }
}

struct PriorityReasonTests {
    @Test func explainsTheChosenLevel() {
        #expect(MacOSUpdateService.priorityReason(for: [], updateAvailable: false).contains("latest"))
        let exploited = SecurityRelease(title: "", version: "1", releaseDate: "", url: nil, issueCount: 1, cveIDs: [],
                                        groups: [], exploitedInTheWild: true)
        #expect(MacOSUpdateService.priorityReason(for: [exploited], updateAvailable: true).contains("exploited"))
    }
}
