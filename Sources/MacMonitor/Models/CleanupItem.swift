import SwiftUI

/// Categories the Storage Cleaner analyzes.
enum CleanupCategory: String, CaseIterable, Identifiable, Sendable {
    case appCaches, browserCaches, appLogs, tempFiles, crashReports,
         diagnosticReports, trash, xcodeCaches, devTempFiles, largeFiles

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appCaches: "Application Caches"
        case .browserCaches: "Browser Caches"
        case .appLogs: "Application Logs"
        case .tempFiles: "Temporary Files"
        case .crashReports: "Old Crash Reports"
        case .diagnosticReports: "Old Diagnostic Reports"
        case .trash: "Trash Bin"
        case .xcodeCaches: "Xcode Caches"
        case .devTempFiles: "Developer Caches"
        case .largeFiles: "Large Files (manual review)"
        }
    }

    /// One sentence shown under the category name.
    var explanation: String {
        switch self {
        case .appCaches: "Data apps saved to load faster. Apps rebuild it when needed."
        case .browserCaches: "Saved copies of web pages and images. Never cookies, passwords or history."
        case .appLogs: "Text records apps write while running, mostly for troubleshooting."
        case .tempFiles: "Leftovers in your temporary folder that haven't changed for 3+ days."
        case .crashReports: "Reports about app crashes, older than 30 days."
        case .diagnosticReports: "Hang, spin and resource reports, older than 30 days."
        case .trash: "Files you already moved to the Trash."
        case .xcodeCaches: "Xcode build data (DerivedData), simulator caches and device support."
        case .devTempFiles: "Package-manager download caches (Homebrew, pip, npm, Swift…)."
        case .largeFiles: "Files over 500 MB in your personal folders. Review these yourself."
        }
    }

    var systemImage: String {
        switch self {
        case .appCaches: "shippingbox"
        case .browserCaches: "globe"
        case .appLogs: "doc.text"
        case .tempFiles: "clock.arrow.circlepath"
        case .crashReports: "exclamationmark.triangle"
        case .diagnosticReports: "stethoscope"
        case .trash: "trash"
        case .xcodeCaches: "hammer"
        case .devTempFiles: "terminal"
        case .largeFiles: "doc.badge.ellipsis"
        }
    }

    var tint: Color {
        switch self {
        case .appCaches: .blue
        case .browserCaches: .teal
        case .appLogs: .indigo
        case .tempFiles: .orange
        case .crashReports: .red
        case .diagnosticReports: .pink
        case .trash: .gray
        case .xcodeCaches: .cyan
        case .devTempFiles: .mint
        case .largeFiles: .purple
        }
    }

    /// Counted in "Potentially recoverable"? Large files are personal data,
    /// so they are only listed for review.
    var countsAsRecoverable: Bool { self != .largeFiles }

    /// Can items in this category be selected for cleanup at all? Large files
    /// are personal documents, downloads or videos: MacMonitor only lists them
    /// so you can review them in Finder yourself.
    var isSelectable: Bool { self != .largeFiles }
}

/// How confident we are that removing an item is harmless.
enum RiskLevel: String, Sendable, Comparable {
    case low, medium, high

    var title: String { rawValue.capitalized }
    var color: Color {
        switch self {
        case .low: .green
        case .medium: .orange
        case .high: .red
        }
    }

    private var rank: Int { self == .low ? 0 : self == .medium ? 1 : 2 }
    static func < (a: RiskLevel, b: RiskLevel) -> Bool { a.rank < b.rank }
}

/// A single file or folder found by the scanner.
struct CleanupItem: Identifiable, Sendable, Hashable {
    let url: URL
    let category: CleanupCategory
    /// Bytes on disk (for a folder: everything inside it).
    let size: UInt64
    /// Number of files (1 for a single file).
    let fileCount: Int
    /// Most recent change of the item or anything inside it.
    let modified: Date
    let isDirectory: Bool
    let risk: RiskLevel
    /// Why it got this risk level, in plain English.
    let riskReason: String
    /// The approved folder this item was found in. Phase 10 re-checks that the
    /// item is still inside it before doing anything.
    let root: URL

    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var path: String { url.path }
    /// Non-optional copies so SwiftUI's Table can sort on them.
    var sizeForSorting: UInt64 { size }
    var modifiedForSorting: Date { modified }
}

/// Outcome of scanning one category.
enum CategoryStatus: Sendable, Equatable {
    case scanned
    /// None of this category's folders exist on this Mac (e.g. no Xcode).
    case notPresent
    /// macOS blocked access; needs Full Disk Access (e.g. the Trash).
    case needsPermission
    /// Turned off by the user (large files).
    case skipped
}

/// All findings for one category.
struct CategoryReport: Identifiable, Sendable {
    var id: CleanupCategory { category }
    let category: CleanupCategory
    var items: [CleanupItem]
    var status: CategoryStatus
    /// Extra information, e.g. "12 recent reports kept" or "2 folders couldn't be read".
    var notes: [String] = []

    var size: UInt64 { items.reduce(0) { $0 + $1.size } }
    var fileCount: Int { items.reduce(0) { $0 + $1.fileCount } }
}

/// Result of a full scan.
struct ScanReport: Sendable {
    let categories: [CategoryReport]
    let date: Date
    let duration: Duration

    var recoverableSize: UInt64 {
        categories.filter(\.category.countsAsRecoverable).reduce(0) { $0 + $1.size }
    }
    var analyzedSize: UInt64 { categories.reduce(0) { $0 + $1.size } }
    var fileCount: Int { categories.reduce(0) { $0 + $1.fileCount } }
    var itemCount: Int { categories.reduce(0) { $0 + $1.items.count } }

    func report(for category: CleanupCategory) -> CategoryReport? {
        categories.first { $0.category == category }
    }

    /// The same report without the given items (after they were cleaned).
    func removing(_ paths: Set<String>) -> ScanReport {
        ScanReport(categories: categories.map { category in
            var copy = category
            copy.items.removeAll { paths.contains($0.id) }
            return copy
        }, date: date, duration: duration)
    }
}

/// Progress while scanning.
struct ScanProgress: Sendable, Equatable {
    var category: CleanupCategory
    var step: Int
    var totalSteps: Int
    var filesSeen: Int
}
