import Foundation
import Testing
@testable import MacMonitor

/// Builds a fake Applications folder and home Library in a temp directory.
struct FakeApps {
    let root: URL
    var applications: URL { root.appending(path: "Applications") }
    var home: URL { root.appending(path: "home") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "MMStorage-\(UUID().uuidString)").resolvingSymlinksInPath()
        try makeApp("Alpha", id: "com.example.alpha", bytes: 300_000, in: applications)
        try makeApp("Beta", id: "com.example.beta", bytes: 100_000, in: applications.appending(path: "Utilities"))
        // An app with the same *name* elsewhere: its name-based data must not be counted twice.
        try makeApp("Alpha", id: "com.example.alpha2", bytes: 50_000, in: root.appending(path: "Other"))
        try FileManager.default.createSymbolicLink(at: applications.appending(path: "Linked.app"),
                                                   withDestinationURL: applications.appending(path: "Alpha.app"))
        try write(home.appending(path: "Library/Application Support/com.example.alpha/db.sqlite"), 200_000)
        try write(home.appending(path: "Library/Caches/com.example.alpha/blob"), 40_000)
        try write(home.appending(path: "Library/Application Support/Alpha/state.json"), 10_000)
        try write(home.appending(path: "Library/Preferences/com.example.beta.plist"), 1_000)
    }

    func makeApp(_ name: String, id: String, bytes: Int, in folder: URL) throws {
        let contents = folder.appending(path: "\(name).app/Contents")
        try FileManager.default.createDirectory(at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundleExecutable": name]
        try (try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0))
            .write(to: contents.appending(path: "Info.plist"))
        try Data(repeating: 1, count: bytes).write(to: contents.appending(path: "MacOS/\(name)"))
    }

    func write(_ url: URL, _ bytes: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 2, count: bytes).write(to: url)
    }

    func snapshot() -> [String] {
        (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? []).sorted()
    }
}

struct StorageAnalyzerTests {
    @Test func findsAppsIncludingSubfoldersButNotSymlinks() throws {
        let fake = try FakeApps()
        let names = StorageAnalyzerService.findApplications(in: [fake.applications]).map(\.lastPathComponent).sorted()
        #expect(names == ["Alpha.app", "Beta.app"])
    }

    @Test func measuresBundleAndUserDataSeparately() async throws {
        let fake = try FakeApps()
        let analysis = try await StorageAnalyzerService.analyzeApplications(
            folders: [fake.applications, fake.root.appending(path: "Other")], home: fake.home) { _ in }
        let alpha = try #require(analysis.entries.first { $0.bundleIdentifier == "com.example.alpha" })
        #expect(alpha.size >= 300_000)
        // Application Support + Caches by bundle ID, and Application Support/Alpha by name.
        #expect(alpha.userDataSize ?? 0 >= 250_000)
        #expect(alpha.userDataPaths.count == 3)
        #expect(alpha.totalSize == alpha.size + (alpha.userDataSize ?? 0))
        #expect(analysis.entries.first?.bundleIdentifier == "com.example.alpha")   // largest first
    }

    @Test func sharedDataIsCountedForOneAppOnly() async throws {
        let fake = try FakeApps()
        let analysis = try await StorageAnalyzerService.analyzeApplications(
            folders: [fake.applications, fake.root.appending(path: "Other")], home: fake.home) { _ in }
        let counted = analysis.entries.flatMap(\.userDataPaths).map(\.path)
        #expect(counted.count == Set(counted).count)
        #expect(counted.filter { $0.hasSuffix("Application Support/Alpha") }.count == 1)
    }

    @Test func unknownLastOpenedStaysUnknown() async throws {
        let fake = try FakeApps()
        let analysis = try await StorageAnalyzerService.analyzeApplications(folders: [fake.applications], home: fake.home) { _ in }
        // Brand-new fake apps were never launched: no date may be invented.
        #expect(analysis.entries.allSatisfy { $0.lastOpened == nil })
        #expect(analysis.entries.allSatisfy { $0.modified != nil })   // modification date is separate
    }

    @Test func folderAnalysisSkipsProtectedFoldersAndLinks() async throws {
        let fake = try FakeApps()
        let library = fake.home.appending(path: "Library")
        try fake.write(library.appending(path: "Containers/com.other.app/Data/secret"), 5_000)
        try FileManager.default.createSymbolicLink(at: library.appending(path: "link-to-root"), withDestinationURL: URL(fileURLWithPath: "/"))

        let analysis = try await StorageAnalyzerService.analyzeFolder(library) { _ in }
        let names = analysis.entries.map(\.name)
        #expect(!names.contains("Containers"))
        #expect(!names.contains("link-to-root"))
        #expect(names.contains("Application Support"))
        #expect(analysis.notes.contains { $0.contains("Containers") })
        let support = try #require(analysis.entries.first { $0.name == "Application Support" })
        #expect(support.kind == .folder && support.size >= 210_000)
    }

    @Test func analysisIsReadOnly() async throws {
        let fake = try FakeApps()
        let before = fake.snapshot()
        _ = try await StorageAnalyzerService.analyzeApplications(folders: [fake.applications], home: fake.home) { _ in }
        _ = try await StorageAnalyzerService.analyzeFolder(fake.root) { _ in }
        #expect(fake.snapshot() == before)
    }

    @Test func protectedPathRules() {
        #expect(StorageAnalyzerService.isProtected(URL(fileURLWithPath: "/Users/x/Library/Containers")))
        #expect(StorageAnalyzerService.isProtected(URL(fileURLWithPath: "/Users/x/Pictures/Photos Library.photoslibrary")))
        #expect(!StorageAnalyzerService.isProtected(URL(fileURLWithPath: "/Users/x/Library/Caches")))
    }
}

struct CategorySelectionTests {
    func item(_ path: String, _ category: CleanupCategory, size: UInt64 = 10, folder: Bool = true) -> CleanupItem {
        CleanupItem(url: URL(fileURLWithPath: path), category: category, size: size, fileCount: 1, modified: .distantPast,
                    isDirectory: folder, risk: .low, riskReason: "", root: URL(fileURLWithPath: "/r"))
    }

    @MainActor @Test func categoryCheckboxStates() {
        let vm = DashboardViewModel()
        let report = CategoryReport(category: .appCaches,
                                    items: [item("/r/a", .appCaches), item("/r/b", .appCaches)], status: .scanned)
        #expect(vm.selectionState(of: report) == .none)
        vm.setSelected(report.items[0], true)
        #expect(vm.selectionState(of: report) == .some)          // indeterminate
        vm.toggleCategory(report)
        #expect(vm.selectionState(of: report) == .all)
        #expect(vm.selectedSize(in: report) == 20)
        vm.toggleCategory(report)
        #expect(vm.selectionState(of: report) == .none)
    }

    @MainActor @Test func largeFilesCannotBeSelected() {
        let vm = DashboardViewModel()
        let report = CategoryReport(category: .largeFiles, items: [item("/r/movie.mov", .largeFiles, folder: false)], status: .scanned)
        vm.toggleCategory(report)
        vm.setSelected(report.items[0], true)
        #expect(vm.cleanerSelection.isEmpty)
        #expect(vm.selectionState(of: report) == .none)
    }

    @Test func planDropsNestedItemsAndLargeFiles() {
        let plan = CleanupPlan(items: [item("/r/cache", .appCaches, size: 100),
                                       item("/r/cache/inner", .appCaches, size: 40),   // inside the one above
                                       item("/r/cachex", .appCaches, size: 5),         // similar name, not inside
                                       item("/r/movie.mov", .largeFiles, size: 900, folder: false)],
                               scanDate: Date())
        #expect(plan.items.map(\.path) == ["/r/cache", "/r/cachex"])
        #expect(plan.totalSize == 105)
    }
}

struct LastOpenedTrustTests {
    let date = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func dateWithoutUsageRecordIsNotTrusted() {
        // What Spotlight returns for a never-opened item: its creation date.
        #expect(StorageAnalyzerService.trustedLastOpened(lastUsed: date, useCount: nil, usedDatesCount: nil) == nil)
        #expect(StorageAnalyzerService.trustedLastOpened(lastUsed: date, useCount: 0, usedDatesCount: 0) == nil)
    }

    @Test func realLaunchesAreTrusted() {
        #expect(StorageAnalyzerService.trustedLastOpened(lastUsed: date, useCount: 399, usedDatesCount: nil) == date)
        #expect(StorageAnalyzerService.trustedLastOpened(lastUsed: date, useCount: nil, usedDatesCount: 3) == date)
        #expect(StorageAnalyzerService.trustedLastOpened(lastUsed: nil, useCount: 5, usedDatesCount: 5) == nil)
    }
}
