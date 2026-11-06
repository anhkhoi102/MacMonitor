import Darwin
import Foundation

/// Re-checks every approved item right before cleanup (Phase 9, used by
/// `CleanupExecutor` in Phase 10).
/// **Read-only**: it only looks at files, it never changes them.
///
/// Files can change between the scan and the moment you confirm – an app may
/// delete its cache, a folder may be replaced, or (in an attack) a folder may
/// be swapped for a symbolic link pointing somewhere important. So each item
/// must pass every rule again, and anything that fails is skipped, never
/// "fixed up" or widened:
///
///  1. Its root folder is one of the scanner's approved folders.
///  2. It is strictly *inside* that root (never the root itself, no `..`).
///  3. It is not under a system location (/System, /usr, /Applications, …).
///  4. It still exists (otherwise: "already gone", nothing to do).
///  5. It is still a regular file or folder – not a symbolic link, socket, etc.
///  6. It is still the same kind (file vs folder) as when scanned.
///  7. It is still owned by you.
///  8. It hasn't been modified since the scan (otherwise: rescan first).
///
/// `CleanupExecutor` runs these checks immediately before moving each item.
enum CleanupValidator {
    /// Never act on anything under these, whatever else is true.
    static let systemPrefixes = ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/", "/Applications/",
                                 "/private/etc/", "/private/var/db/", "/Volumes/", "/cores/"]

    static func check(_ item: CleanupItem, allowedRoots: [URL], scanDate: Date) -> ItemVerdict {
        // 1. Approved root folder.
        let root = canonical(item.root)
        guard allowedRoots.contains(where: { canonical($0) == root }) else {
            return .rejected("Its folder is not one of the approved cleanup locations.")
        }
        // 2. Strictly inside the root.
        guard CleanerScanner.isInside(item.url, root: item.root), canonical(item.url) != root else {
            return .rejected("Its path points outside the approved folder.")
        }
        // 3. Not a system location (defence in depth).
        let path = canonical(item.url) + (item.isDirectory ? "/" : "")
        if systemPrefixes.contains(where: { path.hasPrefix($0) }) {
            return .rejected("It is inside a protected system location.")
        }
        // 4. Still exists? (lstat looks at the item itself, never through a link.)
        var info = Darwin.stat()
        if lstat(item.path, &info) != 0 {
            return errno == ENOENT ? .missing : .rejected("macOS wouldn't let MacMonitor check it.")
        }
        // 5. Still a plain file or folder.
        let kind = info.st_mode & S_IFMT
        if kind == S_IFLNK { return .rejected("It has become a symbolic link.") }
        guard kind == S_IFREG || kind == S_IFDIR else {
            return .rejected("It is no longer a regular file or folder.")
        }
        // 6. Same kind as scanned.
        if (kind == S_IFDIR) != item.isDirectory {
            return .changed(item.isDirectory ? "It was a folder and is now a file." : "It was a file and is now a folder.")
        }
        // 7. Still yours.
        guard info.st_uid == getuid() else { return .rejected("It is owned by another user.") }
        // 8. Unchanged since the scan.
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
        if modified > scanDate.addingTimeInterval(1) {
            return .changed("Modified at \(modified.formatted(date: .omitted, time: .shortened)), after the scan. Rescan to include it.")
        }
        if kind == S_IFREG, UInt64(info.st_blocks) * 512 != item.size {
            return .changed("Its size changed after the scan. Rescan to include it.")
        }
        return .ready
    }

    /// Absolute path with `..` and symbolic links in parent folders resolved.
    ///
    /// Uses the C library's `realpath`, which returns the true path the same
    /// way the kernel reports open files (e.g. "/private/var/folders/…").
    /// Foundation's `resolvingSymlinksInPath()` and `standardizedFileURL` both
    /// strip "/private" again, so paths from the two would never match – a bug
    /// found by a unit test. The final path is therefore built as a plain string.
    static func canonical(_ url: URL) -> String {
        let name = url.lastPathComponent
        if name == "." || name == ".." || name.isEmpty {
            return realPath(url.path) ?? url.path
        }
        let parent = url.deletingLastPathComponent().path
        let resolvedParent = realPath(parent) ?? parent
        return resolvedParent.hasSuffix("/") ? resolvedParent + name : resolvedParent + "/" + name
    }

    private static func realPath(_ path: String) -> String? {
        guard let real = realpath(path, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
    }
}

extension CleanerScanner {
    /// Every folder the scanner may take items from. Items whose root isn't
    /// in this list are never acted on.
    static func allowedRoots(_ o: Options) -> [URL] {
        var roots = [
            o.home.appending(path: "Library/Caches"),
            o.home.appending(path: "Library/Logs"),
            o.home.appending(path: "Library/Logs/DiagnosticReports"),
            o.home.appending(path: ".Trash"),
            o.temporaryDirectory.standardizedFileURL,
        ]
        roots += developerHomePaths.map { o.home.appending(path: $0).deletingLastPathComponent() }
        roots += xcodeHomePaths.map { o.home.appending(path: $0).deletingLastPathComponent() }
        roots += largeFileFolders.map { o.home.appending(path: $0) }
        return roots
    }
}
