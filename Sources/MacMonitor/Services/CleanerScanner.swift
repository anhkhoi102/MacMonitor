import Darwin
import Foundation

/// Finds files that may be safe to clean up (Phase 8). **Read-only**: this
/// file contains no code that moves, changes or deletes anything.
///
/// ## Safety rules applied while scanning
/// - Only fixed, recognized folders inside your home folder are looked at
///   (plus your personal temporary folder). Nothing system-wide, nothing in
///   other users' folders, no administrator rights.
/// - Symbolic links are never followed and never listed (a link could point
///   anywhere on the disk).
/// - Only regular files and folders are listed. Sockets, pipes and device
///   files (live connections used by running programs) are always skipped.
/// - Empty items (0 bytes) are skipped: nothing to recover, and in the temp
///   folder they are usually placeholders that running programs rely on.
/// - Items must be owned by you (checked with `lstat`).
/// - Every item remembers the approved folder ("root") it came from, so the
///   cleanup step (Phase 10) can re-check it is still inside that folder.
/// - Browser *caches* only – never profiles, cookies, passwords or history,
///   which live in other folders we don't open.
/// - Recently changed items are marked higher risk (an app may be using them).
/// - Large personal files are listed for review only, never counted as
///   "recoverable".
/// - Folders macOS protects (the Trash, Safari's cache) report "needs Full
///   Disk Access" instead of failing silently.
enum CleanerScanner {
    struct Options: Sendable {
        var home: URL = FileManager.default.homeDirectoryForCurrentUser
        var temporaryDirectory: URL = FileManager.default.temporaryDirectory
        var includeLargeFiles = false
        var now = Date()
        var oldReportAge: TimeInterval = 30 * 86_400       // 30 days
        var tempMinimumAge: TimeInterval = 3 * 86_400      // 3 days
        var recentlyUsedWindow: TimeInterval = 86_400      // 24 hours
        var largeFileThreshold: UInt64 = 500_000_000       // 500 MB
    }

    typealias ProgressHandler = @Sendable (ScanProgress) async -> Void

    // MARK: Recognized locations (relative to ~/Library/Caches unless noted)

    static let browserCachePaths = [
        "com.apple.Safari", "Google/Chrome", "com.google.Chrome", "Firefox",
        "Microsoft Edge", "com.microsoft.edgemac", "BraveSoftware/Brave-Browser",
        "com.brave.Browser", "com.operasoftware.Opera", "Vivaldi", "com.vivaldi.Vivaldi",
        "company.thebrowser.Browser", "CocCoc", "com.coccoc.Coccoc",
    ]
    static let developerCachePaths = [
        "Homebrew", "pip", "org.swift.swiftpm", "Yarn", "CocoaPods", "go-build", "node-gyp", "pnpm",
    ]
    /// Developer caches outside ~/Library/Caches (relative to home).
    static let developerHomePaths = [".npm/_cacache", ".cache/pip", ".gradle/caches", ".cargo/registry/cache"]
    /// Xcode locations (relative to home).
    static let xcodeHomePaths = [
        "Library/Developer/Xcode/DerivedData", "Library/Developer/Xcode/iOS DeviceSupport",
        "Library/Developer/CoreSimulator/Caches", "Library/Caches/com.apple.dt.Xcode",
    ]
    /// Folders scanned for large files when that option is on (relative to home).
    static let largeFileFolders = ["Downloads", "Desktop", "Documents", "Movies"]

    // MARK: - Scan

    @concurrent
    static func scan(options: Options = Options(), progress: ProgressHandler) async throws -> ScanReport {
        let start = ContinuousClock.now
        let counter = FileCounter()
        var reports: [CategoryReport] = []
        let all = CleanupCategory.allCases

        for (index, category) in all.enumerated() {
            try Task.checkCancellation()
            await progress(ScanProgress(category: category, step: index, totalSteps: all.count, filesSeen: counter.value))
            reports.append(try await scan(category, options: options, counter: counter))
        }
        await progress(ScanProgress(category: all.last!, step: all.count, totalSteps: all.count, filesSeen: counter.value))
        return ScanReport(categories: reports, date: options.now, duration: ContinuousClock.now - start)
    }

    static func scan(_ category: CleanupCategory, options o: Options, counter: FileCounter) async throws -> CategoryReport {
        let caches = o.home.appending(path: "Library/Caches")
        var builder = ReportBuilder(category: category, options: o, counter: counter)

        switch category {
        case .appCaches:
            // Every folder in ~/Library/Caches except the ones that belong to
            // the browser, developer and Xcode categories (no double counting).
            let claimed = Set(browserCachePaths + developerCachePaths + ["com.apple.dt.Xcode"])
            guard let children = builder.list(caches, root: caches) else { break }
            for child in children {
                let name = child.lastPathComponent
                if claimed.contains(name) { continue }
                let nested = claimed.filter { $0.hasPrefix(name + "/") }
                if nested.isEmpty {
                    try builder.add(child, root: caches)
                } else {
                    // e.g. "Google" holds "Google/Chrome": list Google's other
                    // sub-folders individually so Chrome isn't counted twice.
                    for grandchild in builder.list(child, root: caches) ?? []
                    where !nested.contains(name + "/" + grandchild.lastPathComponent) {
                        try builder.add(grandchild, root: caches)
                    }
                }
            }

        case .browserCaches:
            for path in browserCachePaths {
                try builder.addIfPresent(caches.appending(path: path), root: caches)
            }

        case .devTempFiles:
            for path in developerCachePaths {
                try builder.addIfPresent(caches.appending(path: path), root: caches)
            }
            for path in developerHomePaths {
                let url = o.home.appending(path: path)
                try builder.addIfPresent(url, root: url.deletingLastPathComponent())
            }

        case .xcodeCaches:
            for path in xcodeHomePaths {
                let url = o.home.appending(path: path)
                try builder.addIfPresent(url, root: url.deletingLastPathComponent())
            }

        case .appLogs:
            let logs = o.home.appending(path: "Library/Logs")
            for child in builder.list(logs, root: logs) ?? [] where child.lastPathComponent != "DiagnosticReports" {
                try builder.add(child, root: logs)
            }

        case .crashReports, .diagnosticReports:
            let reportsFolder = o.home.appending(path: "Library/Logs/DiagnosticReports")
            var candidates = builder.list(reportsFolder, root: reportsFolder) ?? []
            if let retired = builder.list(reportsFolder.appending(path: "Retired"), root: reportsFolder) {
                candidates += retired
            }
            var keptRecent = 0
            for file in candidates where !isDirectory(file) {
                guard isDiagnostic(file.lastPathComponent) == (category == .diagnosticReports) else { continue }
                if let modified = modificationDate(file), o.now.timeIntervalSince(modified) < o.oldReportAge {
                    keptRecent += 1
                    continue
                }
                try builder.add(file, root: reportsFolder)
            }
            if keptRecent > 0 { builder.notes.append("\(keptRecent) report(s) from the last 30 days kept") }

        case .tempFiles:
            let temp = o.temporaryDirectory.standardizedFileURL
            var keptRecent = 0, keptSystem = 0
            for child in builder.list(temp, root: temp) ?? [] {
                if child.lastPathComponent.hasPrefix("com.apple.") { keptSystem += 1; continue }
                if let modified = latestModification(child), o.now.timeIntervalSince(modified) < o.tempMinimumAge {
                    keptRecent += 1
                    continue
                }
                try builder.add(child, root: temp)
            }
            if keptRecent > 0 { builder.notes.append("\(keptRecent) item(s) changed in the last 3 days kept") }
            if keptSystem > 0 { builder.notes.append("\(keptSystem) macOS system item(s) left alone") }

        case .trash:
            let trash = o.home.appending(path: ".Trash")
            for child in builder.list(trash, root: trash) ?? [] {
                try builder.add(child, root: trash)
            }

        case .largeFiles:
            guard o.includeLargeFiles else { return CategoryReport(category: category, items: [], status: .skipped) }
            for folder in largeFileFolders {
                try builder.addLargeFiles(in: o.home.appending(path: folder))
            }
        }
        return builder.finish()
    }

    // MARK: - Pure rules (unit-tested)

    /// Risk level and the reason shown to the user.
    static func assess(_ category: CleanupCategory, name: String, path: String,
                       modified: Date, now: Date, recentWindow: TimeInterval) -> (RiskLevel, String) {
        var (risk, reason): (RiskLevel, String) = switch category {
        case .appCaches where name.hasPrefix("com.apple."):
            (.medium, "Cache of macOS or an Apple app. It is rebuilt automatically, but that app may be slower for a while.")
        case .appCaches:
            (.low, "App cache. The app rebuilds it automatically when needed.")
        case .browserCaches:
            (.low, "Browser cache only. Cookies, passwords, bookmarks and history are stored elsewhere and are not touched.")
        case .appLogs:
            (.low, "Log file. Only useful for troubleshooting.")
        case .crashReports, .diagnosticReports:
            (.low, "Report older than 30 days. Only useful for troubleshooting.")
        case .tempFiles:
            (.medium, "Temporary file. Unchanged for 3+ days, but an app could still expect it.")
        case .trash:
            (.high, "Removing items from the Trash is permanent.")
        case .xcodeCaches where path.contains("iOS DeviceSupport"):
            (.medium, "Device support files. Xcode re-downloads them when you connect that device again.")
        case .xcodeCaches:
            (.low, "Xcode build cache. Rebuilt on the next build (the first build will be slower).")
        case .devTempFiles:
            (.low, "Download cache. Packages are downloaded again when needed.")
        case .largeFiles:
            (.high, "Personal file. Check whether you still need it.")
        }
        if risk == .low, now.timeIntervalSince(modified) < recentWindow {
            risk = .medium
            reason = "Changed in the last 24 hours, so an app may be using it right now. " + reason
        }
        return (risk, reason)
    }

    /// Hang/spin/resource reports are "diagnostic"; everything else is a crash.
    static func isDiagnostic(_ fileName: String) -> Bool {
        let lower = fileName.lowercased()
        return ["hang", "spin", ".diag", "_resource", "shutdownstall", "jetsam", "stackshot"]
            .contains { lower.contains($0) }
    }

    /// True if `url` is inside `root` (after resolving `..` and links in the root).
    static func isInside(_ url: URL, root: URL) -> Bool {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let itemParent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        let item = itemParent + "/" + url.lastPathComponent
        return item.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
            && !url.lastPathComponent.isEmpty && url.lastPathComponent != ".." && url.lastPathComponent != "."
    }

    // MARK: - File-system helpers

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Latest change of a file, or of anything inside a folder (top two levels:
    /// enough to spot an active temp folder without a full walk).
    static func latestModification(_ url: URL) -> Date? {
        var latest = modificationDate(url)
        if isDirectory(url),
           let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for child in children.prefix(500) {
                if let date = modificationDate(child), date > (latest ?? .distantPast) { latest = date }
            }
        }
        return latest
    }
}

/// Counts files seen during a scan (for the progress display).
final class FileCounter: @unchecked Sendable {
    // Only touched by the single task running the scan.
    private(set) var value = 0
    func add(_ n: Int) { value += n }
}

/// Collects items for one category and enforces the per-item safety checks.
struct ReportBuilder {
    let category: CleanupCategory
    let options: CleanerScanner.Options
    let counter: FileCounter
    var items: [CleanupItem] = []
    var notes: [String] = []
    private var sawPermissionDenied = false
    private var sawAnyFolder = false
    private var skippedLinks = 0
    private var skippedSpecial = 0
    private var skippedEmpty = 0
    private var skippedNotOwned = 0
    private var unreadable = 0

    init(category: CleanupCategory, options: CleanerScanner.Options, counter: FileCounter) {
        self.category = category
        self.options = options
        self.counter = counter
    }

    /// Lists a folder's direct contents. nil if it doesn't exist or can't be read.
    mutating func list(_ folder: URL, root: URL) -> [URL]? {
        do {
            let children = try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey], options: [])
            sawAnyFolder = true
            return children
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            sawAnyFolder = true
            sawPermissionDenied = true
            return nil
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EPERM) {
            sawAnyFolder = true
            sawPermissionDenied = true
            return nil
        } catch {
            return nil   // doesn't exist
        }
    }

    mutating func addIfPresent(_ url: URL, root: URL) throws {
        var stat = Darwin.stat()
        guard lstat(url.path, &stat) == 0 else { return }   // not on this Mac
        sawAnyFolder = true
        try add(url, root: root)
    }

    /// Measures one file or folder and adds it as a reviewable item.
    mutating func add(_ url: URL, root: URL) throws {
        try Task.checkCancellation()
        var stat = Darwin.stat()
        guard lstat(url.path, &stat) == 0 else { return }
        let kind = stat.st_mode & S_IFMT
        if kind == S_IFLNK { skippedLinks += 1; return }                         // never follow links
        guard kind == S_IFREG || kind == S_IFDIR else { skippedSpecial += 1; return }  // no sockets/pipes/devices
        if stat.st_uid != getuid() { skippedNotOwned += 1; return }              // only your own files
        guard CleanerScanner.isInside(url, root: root) else { return }            // no path tricks

        let isFolder = (stat.st_mode & S_IFMT) == S_IFDIR
        let ownDate = Date(timeIntervalSince1970: TimeInterval(stat.st_mtimespec.tv_sec))
        var size: UInt64, files: Int, latest: Date
        if isFolder {
            guard let measured = try measureFolder(url) else {
                sawPermissionDenied = true
                unreadable += 1
                return
            }
            (size, files, latest) = (measured.size, measured.files, max(measured.latest, ownDate))
        } else {
            size = UInt64(stat.st_blocks) * 512   // space actually used on disk
            files = 1
            latest = ownDate
            counter.add(1)
        }
        guard size > 0 else { skippedEmpty += 1; return }
        let (risk, reason) = CleanerScanner.assess(category, name: url.lastPathComponent, path: url.path,
                                                   modified: latest, now: options.now,
                                                   recentWindow: options.recentlyUsedWindow)
        items.append(CleanupItem(url: url, category: category, size: size, fileCount: files,
                                 modified: latest, isDirectory: isFolder, risk: risk,
                                 riskReason: reason, root: root))
    }

    /// Adds every file ≥ the threshold in `folder` (recursively, skipping
    /// app bundles/packages and hidden files).
    mutating func addLargeFiles(in folder: URL) throws {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .isSymbolicLinkKey]
        let denied = LockedFlag()
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants, .skipsHiddenFiles],
            errorHandler: { _, _ in denied.set(); return true })
        else { return }
        sawAnyFolder = true
        var seen = 0
        for case let url as URL in enumerator {
            seen += 1
            if seen.isMultiple(of: 1_000) { try Task.checkCancellation(); counter.add(1_000) }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  UInt64(values.totalFileAllocatedSize ?? 0) >= options.largeFileThreshold
            else { continue }
            try add(url, root: folder)
        }
        if denied.isSet { notes.append("Some files in \(folder.lastPathComponent) couldn't be read") }
    }

    /// Total size, file count and latest change of everything in a folder.
    /// Returns nil if macOS refuses access to the folder itself.
    private func measureFolder(_ url: URL) throws -> (size: UInt64, files: Int, latest: Date)? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .contentModificationDateKey]
        let problems = LockedFlag()
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys, options: [],
            errorHandler: { _, _ in problems.set(); return true })
        else { return nil }

        var size: UInt64 = 0, files = 0, latest = Date.distantPast
        for case let file as URL in enumerator {   // the enumerator never follows symbolic links
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { continue }
            if let date = values.contentModificationDate, date > latest { latest = date }
            guard values.isRegularFile == true else { continue }
            size += UInt64(values.totalFileAllocatedSize ?? 0)
            files += 1
            if files.isMultiple(of: 1_000) { try Task.checkCancellation(); counter.add(1_000) }
        }
        counter.add(files % 1_000)
        if problems.isSet && files == 0 { return nil }
        return (size, files, latest)
    }

    func finish() -> CategoryReport {
        var notes = self.notes
        if skippedLinks > 0 { notes.append("\(skippedLinks) symbolic link(s) ignored for safety") }
        if skippedSpecial > 0 { notes.append("\(skippedSpecial) socket/pipe(s) of running programs left alone") }
        if skippedEmpty > 0 { notes.append("\(skippedEmpty) empty item(s) ignored") }
        if skippedNotOwned > 0 { notes.append("\(skippedNotOwned) item(s) owned by another user ignored") }
        if unreadable > 0 { notes.append("\(unreadable) folder(s) protected by macOS (need Full Disk Access)") }

        let status: CategoryStatus
        if sawPermissionDenied && items.isEmpty { status = .needsPermission }
        else if !sawAnyFolder { status = .notPresent }
        else { status = .scanned }
        return CategoryReport(category: category, items: items.sorted { $0.size > $1.size },
                              status: status, notes: notes)
    }
}

/// A thread-safe yes/no flag for FileManager's error callback.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.withLock { flag = true } }
    var isSet: Bool { lock.withLock { flag } }
}
