import Foundation
import Testing
@testable import MacMonitor

/// Moves items into this folder instead of your real Trash.
struct FakeTrash: ItemRemover {
    let folder: URL
    func moveToTrash(_ url: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: folder.appending(path: url.lastPathComponent))
    }
    func deletePermanently(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

/// Real cleanup runs, entirely inside a fake home folder with a fake Trash.
struct CleanupExecutorTests {
    let fake: FakeHome
    let report: ScanReport
    let trash: FakeTrash

    init() async throws {
        fake = try FakeHome()
        var options = fake.options
        options.now = Date()
        report = try await CleanerScanner.scan(options: options) { _ in }
        trash = FakeTrash(folder: fake.home.deletingLastPathComponent().appending(path: "fake-trash"))
    }

    private func item(_ name: String) throws -> CleanupItem {
        try #require(report.categories.flatMap(\.items).first { $0.name == name })
    }

    private func run(_ items: [CleanupItem], acknowledged: Bool = false,
                     openFiles: OpenFilesSnapshot = OpenFilesSnapshot()) async -> CleanupOutcome {
        await CleanupExecutor.run(CleanupPlan(items: items, scanDate: report.date), trashAcknowledged: acknowledged,
                                  options: fake.options, remover: trash, openFiles: { openFiles }) { _ in }
    }

    @Test func movesApprovedItemsAndNothingElse() async throws {
        let before = try fake.snapshot()
        let cache = try item("com.example.app")
        let logs = try item("SomeApp")
        let outcome = await run([cache, logs])

        #expect(outcome.movedCount == 2)
        #expect(outcome.freedSize == cache.size + logs.size)
        #expect(FileManager.default.fileExists(atPath: trash.folder.appending(path: "com.example.app").path))
        #expect(!FileManager.default.fileExists(atPath: cache.path))

        // Every other file is exactly where it was.
        let after = try fake.snapshot()
        let removed = Set(before.keys).subtracting(after.keys)
        #expect(removed.allSatisfy { $0.hasPrefix(cache.path) || $0.hasPrefix(logs.path) })
        #expect(Set(after.keys).isSubset(of: Set(before.keys)))
    }

    @Test func itemInUseIsSkipped() async throws {
        let cache = try item("com.example.app")
        let open = OpenFilesSnapshot(openPaths: [CleanupValidator.canonical(cache.url) + "/data.bin": ["SomeApp"]])
        let outcome = await run([cache], openFiles: open)
        #expect(outcome.results.first?.kind == .inUse("SomeApp"))
        #expect(FileManager.default.fileExists(atPath: cache.path))
    }

    @Test func realOpenFileIsDetected() throws {
        // This test process opens a file inside the fake cache folder…
        let cache = try item("com.example.app")
        let handle = try FileHandle(forReadingFrom: cache.url.appending(path: "data.bin"))
        defer { try? handle.close() }
        // …and the kernel snapshot must report the folder as in use.
        let users = OpenFilesSnapshot.capture().users(of: CleanupValidator.canonical(cache.url))
        #expect(!users.isEmpty)
    }

    @Test func symlinkSwapIsSkippedAndTargetUntouched() async throws {
        let cache = try item("com.example.app")
        let target = fake.home.appending(path: "Documents")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data([9]).write(to: target.appending(path: "precious.txt"))
        try FileManager.default.removeItem(at: cache.url)
        try FileManager.default.createSymbolicLink(at: cache.url, withDestinationURL: target)

        let outcome = await run([cache])
        guard case .skipped(.rejected) = outcome.results.first?.kind else { Issue.record("expected rejection"); return }
        #expect(FileManager.default.fileExists(atPath: target.appending(path: "precious.txt").path))
    }

    @Test func trashItemsNeedTheSeparateConfirmation() async throws {
        let trashFolder = fake.home.appending(path: ".Trash")
        try Data(repeating: 1, count: 5_000).write(to: trashFolder.appending(path: "old.zip"))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-86_400 * 5)],
                                              ofItemAtPath: trashFolder.appending(path: "old.zip").path)
        var options = fake.options
        options.now = Date()
        let rescan = try await CleanerScanner.scan(options: options) { _ in }
        let inTrash = try #require(rescan.report(for: .trash)?.items.first)

        let notConfirmed = await CleanupExecutor.run(CleanupPlan(items: [inTrash], scanDate: rescan.date),
                                                     trashAcknowledged: false, options: options, remover: trash,
                                                     openFiles: { OpenFilesSnapshot() }) { _ in }
        guard case .skipped = notConfirmed.results.first?.kind else { Issue.record("expected skip"); return }
        #expect(FileManager.default.fileExists(atPath: inTrash.path))

        let confirmed = await CleanupExecutor.run(CleanupPlan(items: [inTrash], scanDate: rescan.date),
                                                  trashAcknowledged: true, options: options, remover: trash,
                                                  openFiles: { OpenFilesSnapshot() }) { _ in }
        #expect(confirmed.deletedCount == 1)
        #expect(!FileManager.default.fileExists(atPath: inTrash.path))
    }

    @Test func stopLeavesRemainingItemsUntouched() async throws {
        let items = [try item("com.example.app"), try item("SomeApp")]
        let task = Task {
            while !Task.isCancelled { await Task.yield() }   // wait until Stop is pressed
            return await run(items)
        }
        task.cancel()
        let outcome = await task.value
        #expect(outcome.wasStopped)
        #expect(outcome.results.allSatisfy { $0.kind == .notAttempted })
        #expect(items.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test func errorsBecomePlainEnglish() {
        if case .failed(let message) = CleanupExecutor.kind(for: CocoaError(.fileWriteNoPermission)) {
            #expect(message.contains("didn't allow"))
        } else { Issue.record("expected failure") }
        #expect(CleanupExecutor.kind(for: CocoaError(.fileNoSuchFile)) == .skipped(.missing))
    }
}
