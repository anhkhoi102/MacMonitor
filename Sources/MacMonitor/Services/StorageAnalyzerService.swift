import CoreServices
import Darwin
import Foundation

/// Disk Space Analyzer (Storage page). **Read-only**: it measures, it never
/// changes, moves or deletes anything. Only runs when you ask, on a
/// background thread, and can be canceled.
///
/// ## Applications
/// Apps in /Applications and ~/Applications (one level of sub-folders, e.g.
/// /Applications/Utilities). For each app:
///   - **App size**: everything inside the .app bundle.
///   - **User data (estimate)**: well-known Library locations named after the
///     app's bundle ID or name – Application Support, Caches, Preferences,
///     Logs, HTTPStorages, WebKit, Saved Application State. Each location is
///     counted for one app only, so nothing is counted twice. Sandboxed apps'
///     `~/Library/Containers` are **not** opened: since macOS 14 that shows a
///     "would like to access data from other apps" prompt for every app.
///   - **Last opened**: Spotlight's `kMDItemLastUsedDate` – when the app was
///     last launched. Shown as "Unknown" if Spotlight doesn't know; never
///     replaced with a file date.
///
/// ## Folders
/// A folder *you choose*. Its direct contents are listed with their total
/// size. Folders macOS guards with privacy prompts for other apps' data
/// (Containers, Mail, Messages, Photos library…) are skipped and reported.
enum StorageAnalyzerService {
    typealias ProgressHandler = @Sendable (StorageAnalysisProgress) async -> Void

    static let applicationFolders: [URL] = [
        URL(fileURLWithPath: "/Applications"),
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications"),
    ]

    /// Inside a scanned folder these are never opened (privacy-protected data
    /// of other apps, or the photo library). Matched on the path's ending.
    static let protectedSuffixes = [
        "/Library/Containers", "/Library/Group Containers", "/Library/Mail", "/Library/Messages",
        "/Library/Safari", "/Library/Cookies", "/Library/Calendars", "/Library/Mobile Documents",
        "/Library/Application Support/AddressBook", "/Library/Application Support/CallHistoryDB",
        "/Library/Application Support/com.apple.TCC", "/Library/Biome", "/Library/Suggestions",
        ".photoslibrary",
    ]

    // MARK: - Applications

    @concurrent
    static func analyzeApplications(folders: [URL] = applicationFolders,
                                     home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                     progress: ProgressHandler) async throws -> StorageAnalysis {
        let start = ContinuousClock.now
        let counter = FileTally()
        var claimed = Set<String>()   // user-data paths already counted for an app
        var entries: [StorageEntry] = []

        for app in findApplications(in: folders) {
            try Task.checkCancellation()
            await progress(StorageAnalysisProgress(current: app.lastPathComponent, filesSeen: counter.count))
            let bundle = try measure(app, counter: counter)
            let bundleID = Bundle(url: app)?.bundleIdentifier
            let name = (app.lastPathComponent as NSString).deletingPathExtension

            var dataSize: UInt64 = 0
            var dataPaths: [URL] = []
            for candidate in userDataCandidates(bundleID: bundleID, appName: name, home: home) {
                let key = candidate.standardizedFileURL.path
                guard !claimed.contains(key), FileManager.default.fileExists(atPath: key) else { continue }
                claimed.insert(key)
                let measured = try measure(candidate, counter: counter)
                guard measured.size > 0 else { continue }
                dataSize += measured.size
                dataPaths.append(candidate)
            }

            entries.append(StorageEntry(url: app, kind: .application, size: bundle.size,
                                        userDataSize: dataSize, userDataPaths: dataPaths,
                                        lastOpened: lastOpened(app), modified: bundle.latest,
                                        bundleIdentifier: bundleID, fileCount: bundle.files))
        }
        return StorageAnalysis(
            source: .applications,
            entries: entries.sorted { $0.totalSize > $1.totalSize },
            notes: ["Apple's built-in apps in /System/Applications live on the read-only system volume and aren't listed.",
                    "User data is an estimate from well-known Library folders. Sandboxed apps' Containers aren't opened, to avoid macOS privacy prompts."],
            date: Date(), duration: ContinuousClock.now - start)
    }

    /// .app bundles in the application folders, including one level of
    /// sub-folders (e.g. Utilities). Symbolic links are skipped.
    static func findApplications(in folders: [URL] = applicationFolders) -> [URL] {
        var apps: [URL] = []
        for folder in folders {
            for item in contents(of: folder) {
                if item.pathExtension == "app" { apps.append(item) }
                else if isPlainDirectory(item) {
                    apps += contents(of: item).filter { $0.pathExtension == "app" }
                }
            }
        }
        return apps.filter { !isSymlink($0) }
    }

    /// Library locations that usually hold an app's own data.
    static func userDataCandidates(bundleID: String?, appName: String, home: URL) -> [URL] {
        let library = home.appending(path: "Library")
        var urls: [URL] = []
        if let id = bundleID, !id.isEmpty {
            urls += [
                library.appending(path: "Application Support/\(id)"),
                library.appending(path: "Caches/\(id)"),
                library.appending(path: "Preferences/\(id).plist"),
                library.appending(path: "Logs/\(id)"),
                library.appending(path: "HTTPStorages/\(id)"),
                library.appending(path: "WebKit/\(id)"),
                library.appending(path: "Saved Application State/\(id).savedState"),
            ]
        }
        if !appName.isEmpty, !appName.contains("/") {
            urls += [library.appending(path: "Application Support/\(appName)"),
                     library.appending(path: "Logs/\(appName)")]
        }
        return urls
    }

    // MARK: - Folders

    @concurrent
    static func analyzeFolder(_ folder: URL, progress: ProgressHandler) async throws -> StorageAnalysis {
        let start = ContinuousClock.now
        let counter = FileTally()
        var entries: [StorageEntry] = []
        var skipped: [String] = []

        for item in contents(of: folder, includeHidden: true) {
            try Task.checkCancellation()
            if isSymlink(item) { continue }
            if isProtected(item) { skipped.append(item.lastPathComponent); continue }
            await progress(StorageAnalysisProgress(current: item.lastPathComponent, filesSeen: counter.count))

            let measured = try measure(item, counter: counter, skipProtected: true)
            let kind: StorageEntry.Kind = item.pathExtension == "app" ? .application
                : (isPlainDirectory(item) || isDirectory(item)) ? .folder : .file
            entries.append(StorageEntry(url: item, kind: kind, size: measured.size, userDataSize: nil, userDataPaths: [],
                                        lastOpened: lastOpened(item), modified: measured.latest,
                                        bundleIdentifier: nil, fileCount: measured.files))
        }
        var notes: [String] = []
        if !skipped.isEmpty { notes.append("Skipped (private data macOS protects): \(skipped.joined(separator: ", "))") }
        if counter.unreadable > 0 { notes.append("\(counter.unreadable) folder(s) inside couldn't be read and weren't counted.") }
        notes.append("Sizes are space used on disk. Like Finder, files shared through APFS cloning may be counted more than once.")
        return StorageAnalysis(source: .folder(folder), entries: entries.sorted { $0.totalSize > $1.totalSize },
                               notes: notes, date: Date(), duration: ContinuousClock.now - start)
    }

    // MARK: - Helpers (some unit-tested)

    static func isProtected(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return protectedSuffixes.contains { path.hasSuffix($0) }
    }

    /// Spotlight's "last opened" date, or nil if macOS doesn't know.
    ///
    /// Careful: for items macOS has *no* usage record of, Spotlight fills
    /// `kMDItemLastUsedDate` with the file's creation date (found by a unit
    /// test with a never-launched fake app). A real launch also records a use
    /// count and a list of usage dates, so the date is only trusted when one of
    /// those exists. Otherwise the answer is "Unknown", never a file date.
    static func lastOpened(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return trustedLastOpened(
            lastUsed: MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date,
            useCount: (MDItemCopyAttribute(item, "kMDItemUseCount" as CFString) as? NSNumber)?.intValue,
            usedDatesCount: (MDItemCopyAttribute(item, "kMDItemUsedDates" as CFString) as? [Any])?.count)
    }

    static func trustedLastOpened(lastUsed: Date?, useCount: Int?, usedDatesCount: Int?) -> Date? {
        guard let lastUsed else { return nil }
        let hasUsageRecord = (useCount ?? 0) > 0 || (usedDatesCount ?? 0) > 0
        return hasUsageRecord ? lastUsed : nil
    }

    /// Total on-disk size, file count and latest change. Never follows
    /// symbolic links; optionally skips privacy-protected folders inside.
    static func measure(_ url: URL, counter: FileTally, skipProtected: Bool = false) throws
        -> (size: UInt64, files: Int, latest: Date?)
    {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .contentModificationDateKey, .isDirectoryKey]
        let own = try? url.resourceValues(forKeys: keys)
        guard own?.isDirectory == true else {
            counter.add(1)
            return (UInt64(own?.totalFileAllocatedSize ?? 0), 1, own?.contentModificationDate)
        }
        let unreadable = LockedFlag()
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys), options: [],
            errorHandler: { _, _ in unreadable.set(); return true })
        else { return (0, 0, own?.contentModificationDate) }

        var size: UInt64 = 0, files = 0
        var latest = own?.contentModificationDate
        for case let file as URL in enumerator {
            if skipProtected, isProtected(file) { enumerator.skipDescendants(); continue }
            guard let values = try? file.resourceValues(forKeys: keys) else { continue }
            if let date = values.contentModificationDate, date > (latest ?? .distantPast) { latest = date }
            guard values.isRegularFile == true else { continue }
            size += UInt64(values.totalFileAllocatedSize ?? 0)
            files += 1
            if files.isMultiple(of: 2_000) { try Task.checkCancellation() }
        }
        counter.add(files)
        if unreadable.isSet { counter.markUnreadable() }
        return (size, files, latest)
    }

    private static func contents(of folder: URL, includeHidden: Bool = false) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey],
            options: includeHidden ? [] : [.skipsHiddenFiles])) ?? []
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    /// A folder that isn't a package (so not an .app or .photoslibrary).
    private static func isPlainDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }
}

/// Counts files and unreadable folders during one analysis (one task only).
final class FileTally: @unchecked Sendable {
    private(set) var count = 0
    private(set) var unreadable = 0
    func add(_ n: Int) { count += n }
    func markUnreadable() { unreadable += 1 }
}
