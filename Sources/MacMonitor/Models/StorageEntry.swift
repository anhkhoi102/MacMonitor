import Foundation

/// One row of the Disk Space Analyzer: an app, a folder or a file.
struct StorageEntry: Identifiable, Sendable, Hashable {
    enum Kind: String, Sendable, CaseIterable {
        case application = "Application"
        case folder = "Folder"
        case file = "File"
    }

    let url: URL
    let kind: Kind
    /// Space used on disk by the item itself (for an app: the .app bundle).
    let size: UInt64
    /// Apps only: estimated size of the app's data in your Library (caches,
    /// support files, preferences). nil for folders/files.
    let userDataSize: UInt64?
    /// Apps only: the Library folders/files counted in `userDataSize`.
    let userDataPaths: [URL]
    /// When the item was last *opened*, from Spotlight (`kMDItemLastUsedDate`).
    /// nil = macOS doesn't know. Never guessed.
    let lastOpened: Date?
    /// When the item's contents last *changed*. A different thing from
    /// `lastOpened` and shown separately.
    let modified: Date?
    let bundleIdentifier: String?
    /// Files inside (for folders and apps).
    let fileCount: Int

    var id: String { url.path }
    var name: String {
        kind == .application ? (url.lastPathComponent as NSString).deletingPathExtension : url.lastPathComponent
    }
    var path: String { url.path }
    /// Bundle + estimated data (apps); just `size` for folders and files.
    var totalSize: UInt64 { size + (userDataSize ?? 0) }

    // Non-optional values for Table sorting.
    var totalSizeForSorting: UInt64 { totalSize }
    var lastOpenedForSorting: Date { lastOpened ?? .distantPast }
    var modifiedForSorting: Date { modified ?? .distantPast }
}

/// Result of analyzing applications or one folder.
struct StorageAnalysis: Sendable {
    enum Source: Sendable, Hashable {
        case applications
        case folder(URL)
    }

    let source: Source
    let entries: [StorageEntry]
    /// Things that were skipped, explained in plain English.
    let notes: [String]
    let date: Date
    let duration: Duration

    var totalSize: UInt64 { entries.reduce(0) { $0 + $1.totalSize } }
}

/// Progress while analyzing.
struct StorageAnalysisProgress: Sendable, Equatable {
    var current: String
    var filesSeen: Int
}
