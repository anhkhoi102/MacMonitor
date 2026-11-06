import Foundation
import Testing
@testable import MacMonitor

/// Re-validation tests, run on a fake home folder. The validator is read-only;
/// any changes below are made by the *test* to simulate what can happen
/// between scanning and confirming.
struct CleanupValidatorTests {
    let fake: FakeHome
    let report: ScanReport
    let roots: [URL]

    init() async throws {
        fake = try FakeHome()
        var options = fake.options
        options.now = Date()
        report = try await CleanerScanner.scan(options: options) { _ in }
        roots = CleanerScanner.allowedRoots(options)
    }

    private func item(named name: String) throws -> CleanupItem {
        try #require(report.categories.flatMap(\.items).first { $0.name == name })
    }

    private func check(_ item: CleanupItem) -> ItemVerdict {
        CleanupValidator.check(item, allowedRoots: roots, scanDate: report.date)
    }

    @Test func untouchedItemIsReady() throws {
        let cache = try item(named: "com.example.app")
        let logs = try item(named: "SomeApp")
        #expect(check(cache) == .ready)
        #expect(check(logs) == .ready)
    }

    @Test func deletedItemIsAlreadyGone() throws {
        let target = try item(named: "com.example.app")
        try FileManager.default.removeItem(at: target.url)   // simulate the app clearing its own cache
        #expect(check(target) == .missing)
    }

    @Test func folderSwappedForSymlinkIsRejected() throws {
        let target = try item(named: "com.example.app")
        try FileManager.default.removeItem(at: target.url)
        try FileManager.default.createSymbolicLink(at: target.url, withDestinationURL: fake.home.appending(path: "Documents"))
        guard case .rejected(let why) = check(target) else { Issue.record("expected rejection"); return }
        #expect(why.contains("symbolic link"))
    }

    @Test func modifiedAfterScanIsSkipped() throws {
        let target = try item(named: "Homebrew")
        try Data([1, 2, 3]).write(to: target.url.appending(path: "new-download"))  // folder changes after the scan
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: target.path)
        guard case .changed = check(target) else { Issue.record("expected changed"); return }
    }

    @Test func itemWithUnapprovedRootIsRejected() throws {
        let real = try item(named: "com.example.app")
        let forged = CleanupItem(url: URL(fileURLWithPath: "/etc/hosts"), category: .appCaches, size: 1, fileCount: 1,
                                 modified: .distantPast, isDirectory: false, risk: .low, riskReason: "", root: URL(fileURLWithPath: "/etc"))
        guard case .rejected = check(forged) else { Issue.record("expected rejection"); return }
        // Approved root but a path that escapes it with "..".
        let escaping = CleanupItem(url: real.root.appending(path: "../../Documents"), category: .appCaches, size: 1, fileCount: 1,
                                   modified: .distantPast, isDirectory: true, risk: .low, riskReason: "", root: real.root)
        guard case .rejected = check(escaping) else { Issue.record("expected rejection"); return }
    }

    @Test func theRootFolderItselfIsNeverAnItem() throws {
        let real = try item(named: "com.example.app")
        let rootItem = CleanupItem(url: real.root, category: .appCaches, size: 1, fileCount: 1,
                                   modified: .distantPast, isDirectory: true, risk: .low, riskReason: "", root: real.root)
        guard case .rejected = check(rootItem) else { Issue.record("expected rejection"); return }
    }

}

struct CleanupPlanTests {
    func makeItem(_ name: String, _ category: CleanupCategory, size: UInt64, risk: RiskLevel = .low) -> CleanupItem {
        CleanupItem(url: URL(fileURLWithPath: "/tmp/root/\(name)"), category: category, size: size, fileCount: 2,
                    modified: .distantPast, isDirectory: true, risk: risk, riskReason: "", root: URL(fileURLWithPath: "/tmp/root"))
    }

    @Test func totalsAndCategories() {
        let plan = CleanupPlan(items: [makeItem("a", .appCaches, size: 100), makeItem("b", .appLogs, size: 50),
                                       makeItem("c", .appCaches, size: 25)], scanDate: Date())
        #expect(plan.totalSize == 175)
        #expect(plan.fileCount == 6)
        #expect(plan.categories.map(\.category) == [.appCaches, .appLogs])
        #expect(plan.categories.first?.size == 125)
        #expect(plan.items.first?.name == "a")   // largest first
    }

    @Test func duplicatesAreRemoved() {
        let a = makeItem("a", .appCaches, size: 100)
        #expect(CleanupPlan(items: [a, a], scanDate: Date()).items.count == 1)
    }

    @Test func trashNeedsSeparateAcknowledgement() {
        let plan = CleanupPlan(items: [makeItem("t", .trash, size: 1, risk: .high)], scanDate: Date())
        #expect(plan.requiresTrashAcknowledgement)
        #expect(plan.highRiskCount == 1)
        #expect(!CleanupPlan(items: [makeItem("a", .appCaches, size: 1)], scanDate: Date()).requiresTrashAcknowledgement)
    }
}
