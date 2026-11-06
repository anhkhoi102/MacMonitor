import Foundation
import Testing
@testable import MacMonitor

/// Scanner tests run against a fake home folder created in a fresh temporary
/// directory – never against your real files. The scanner is read-only, and
/// these tests also check that it left every file in place.
struct CleanerScannerTests {
    let fake: FakeHome

    init() throws { fake = try FakeHome() }

    private func scan(_ category: CleanupCategory, largeFiles: Bool = false) async throws -> CategoryReport {
        var options = fake.options
        options.includeLargeFiles = largeFiles
        return try await CleanerScanner.scan(category, options: options, counter: FileCounter())
    }

    @Test func appCachesExcludeBrowserAndDeveloperFolders() async throws {
        let report = try await scan(.appCaches)
        let names = Set(report.items.map(\.name))
        #expect(names.contains("com.example.app"))
        #expect(names.contains("Other"))               // Google's non-Chrome sub-folder
        #expect(!names.contains("Google"))             // split so Chrome isn't counted twice
        #expect(!names.contains("Chrome"))
        #expect(!names.contains("Homebrew"))
        #expect(report.items.first { $0.name == "com.example.app" }?.size ?? 0 > 0)
    }

    @Test func browserCachesFoundButNeverProfiles() async throws {
        let report = try await scan(.browserCaches)
        #expect(report.items.map(\.name) == ["Chrome"])
        // The Chrome profile (cookies, passwords) lives in Application Support: never listed.
        #expect(!report.items.contains { $0.path.contains("Application Support") })
    }

    @Test func symbolicLinksAreNeverListed() async throws {
        let report = try await scan(.appCaches)
        #expect(!report.items.contains { $0.name == "sneaky-link" })
        #expect(report.notes.contains { $0.contains("symbolic link") })
    }

    @Test func onlyOldCrashReportsAndCorrectSplit() async throws {
        let crashes = try await scan(.crashReports)
        let diagnostics = try await scan(.diagnosticReports)
        #expect(crashes.items.map(\.name) == ["OldApp-2025-01-01.ips"])
        #expect(diagnostics.items.map(\.name) == ["OldApp_2025-01-01.hang"])
        #expect(crashes.notes.contains { $0.contains("last 30 days") })   // the recent one was kept
    }

    @Test func tempFilesSkipRecentAndSystemItems() async throws {
        let report = try await scan(.tempFiles)
        #expect(report.items.map(\.name) == ["old-download.tmp"])
        #expect(report.items.first?.risk == .medium)
    }

    @Test func logsExcludeDiagnosticReportsFolder() async throws {
        let report = try await scan(.appLogs)
        #expect(report.items.map(\.name) == ["SomeApp"])
    }

    @Test func missingFoldersReportNotPresent() async throws {
        #expect(try await scan(.xcodeCaches).status == .notPresent)
        #expect(try await scan(.largeFiles).status == .skipped)
    }

    @Test func everyItemIsInsideItsRoot() async throws {
        for category in CleanupCategory.allCases {
            for item in try await scan(category).items {
                #expect(CleanerScanner.isInside(item.url, root: item.root), "\(item.path)")
            }
        }
    }

    @Test func scanningChangesNothing() async throws {
        let before = try fake.snapshot()
        _ = try await CleanerScanner.scan(options: fake.options) { _ in }
        #expect(try fake.snapshot() == before)
    }

    @Test func fullScanFindsRecoverableSpace() async throws {
        let report = try await CleanerScanner.scan(options: fake.options) { _ in }
        #expect(report.categories.count == CleanupCategory.allCases.count)
        #expect(report.recoverableSize > 0)
    }
}

/// Pure rule tests.
struct CleanerRuleTests {
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func appleCachesAreMediumRisk() {
        let old = now.addingTimeInterval(-10 * 86_400)
        #expect(CleanerScanner.assess(.appCaches, name: "com.apple.Music", path: "", modified: old, now: now, recentWindow: 86_400).0 == .medium)
        #expect(CleanerScanner.assess(.appCaches, name: "com.spotify.client", path: "", modified: old, now: now, recentWindow: 86_400).0 == .low)
    }

    @Test func recentlyChangedItemsGetHigherRisk() {
        let (risk, reason) = CleanerScanner.assess(.appLogs, name: "x", path: "", modified: now.addingTimeInterval(-60),
                                                   now: now, recentWindow: 86_400)
        #expect(risk == .medium)
        #expect(reason.contains("24 hours"))
    }

    @Test func trashAndLargeFilesAreHighRisk() {
        #expect(CleanerScanner.assess(.trash, name: "a", path: "", modified: .distantPast, now: now, recentWindow: 0).0 == .high)
        #expect(CleanerScanner.assess(.largeFiles, name: "a", path: "", modified: .distantPast, now: now, recentWindow: 0).0 == .high)
    }

    @Test func diagnosticReportNames() {
        #expect(CleanerScanner.isDiagnostic("Safari_2025-01-01-120000_Mac.hang"))
        #expect(CleanerScanner.isDiagnostic("kernel.cpu_resource.diag"))
        #expect(!CleanerScanner.isDiagnostic("Safari-2025-01-01-120000.ips"))
    }

    @Test func pathTraversalIsRejected() {
        let root = URL(fileURLWithPath: "/tmp/cleaner-root")
        #expect(CleanerScanner.isInside(root.appending(path: "cache"), root: root))
        #expect(!CleanerScanner.isInside(URL(fileURLWithPath: "/tmp/cleaner-root/../etc"), root: root))
        #expect(!CleanerScanner.isInside(URL(fileURLWithPath: "/tmp/cleaner-root-evil/x"), root: root))
        #expect(!CleanerScanner.isInside(URL(fileURLWithPath: "/etc/hosts"), root: root))
    }
}

/// Builds a small fake home folder for the scanner tests.
struct FakeHome {
    let home: URL
    let temp: URL
    var options: CleanerScanner.Options {
        var o = CleanerScanner.Options()
        o.home = home
        o.temporaryDirectory = temp
        o.now = Date()
        return o
    }

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "MacMonitorTests-\(UUID().uuidString)").resolvingSymlinksInPath()
        home = base.appending(path: "home")
        temp = base.appending(path: "tmp")
        let old = Date().addingTimeInterval(-60 * 86_400)

        try write("Library/Caches/com.example.app/data.bin", bytes: 50_000, date: old)
        try write("Library/Caches/Google/Chrome/Default/Cache/blob", bytes: 80_000, date: old)
        try write("Library/Caches/Google/Other/file", bytes: 1_000, date: old)
        try write("Library/Caches/Homebrew/bottle.tar.gz", bytes: 30_000, date: old)
        try write("Library/Application Support/Google/Chrome/Default/Cookies", bytes: 100, date: old)
        try write("Library/Logs/SomeApp/app.log", bytes: 2_000, date: old)
        try write("Library/Logs/DiagnosticReports/OldApp-2025-01-01.ips", bytes: 500, date: old)
        try write("Library/Logs/DiagnosticReports/OldApp_2025-01-01.hang", bytes: 500, date: old)
        try write("Library/Logs/DiagnosticReports/NewApp-today.ips", bytes: 500, date: Date())
        try FileManager.default.createDirectory(at: home.appending(path: ".Trash"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appending(path: "Library/Caches/sneaky-link"),
                                                   withDestinationURL: URL(fileURLWithPath: "/System"))
        try write("../tmp/old-download.tmp", bytes: 4_000, date: old)
        try write("../tmp/fresh.tmp", bytes: 4_000, date: Date())
        try write("../tmp/com.apple.something/x", bytes: 100, date: old)
    }

    private func write(_ relative: String, bytes: Int, date: Date) throws {
        let url = home.appending(path: relative).standardizedFileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        // Make parent folders old too, so only the files' own dates matter.
        var folder = url.deletingLastPathComponent()
        while folder.path.count > home.deletingLastPathComponent().path.count {
            try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: folder.path)
            folder = folder.deletingLastPathComponent()
        }
    }

    /// Every path and size under the fake folders, to prove nothing changed.
    func snapshot() throws -> [String: Int] {
        var result: [String: Int] = [:]
        for root in [home, temp] {
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])
            while let url = enumerator?.nextObject() as? URL {
                result[url.path] = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
            }
        }
        return result
    }
}

/// Found during the first real scan: a VS Code socket in the temp folder.
struct SpecialFileTests {
    @Test func socketsAndEmptyItemsAreNeverListed() async throws {
        let fake = try FakeHome()
        // Use a short temp folder: Unix socket paths are limited to 104 bytes.
        let shortTemp = URL(fileURLWithPath: "/tmp/mm-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: shortTemp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: shortTemp) }   // only our own test folder
        // A real Unix socket, like the one VS Code keeps in the temp folder.
        let socketPath = shortTemp.appending(path: "s.sock").path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (i, byte) in socketPath.utf8.prefix(raw.count - 1).enumerated() { raw[i] = byte }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try FileManager.default.createDirectory(at: shortTemp.appending(path: "empty-folder"), withIntermediateDirectories: true)

        var options = fake.options
        options.temporaryDirectory = shortTemp
        options.now = Date().addingTimeInterval(10 * 86_400)   // make everything look "old"
        let report = try await CleanerScanner.scan(.tempFiles, options: options, counter: FileCounter())
        let names = report.items.map(\.name)

        #expect(!names.contains("s.sock"))
        #expect(!names.contains("empty-folder"))
        #expect(bound == 0)
        #expect(report.notes.contains { $0.contains("socket") })
        #expect(report.notes.contains { $0.contains("empty") })
    }
}
