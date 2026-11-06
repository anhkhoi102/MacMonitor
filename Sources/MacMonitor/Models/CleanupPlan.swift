import Foundation

/// The exact list of items the user approved on the confirmation screen.
///
/// It is a frozen copy: changing the selection afterwards does not change an
/// existing plan, and nothing outside `items` can ever be acted on. This is
/// how the app makes sure the cleanup scope never grows beyond what was approved.
struct CleanupPlan: Identifiable, Sendable {
    let id = UUID()
    let items: [CleanupItem]
    let createdAt: Date
    /// When the scan that found these items finished (used to spot changes).
    let scanDate: Date

    init(items: [CleanupItem], scanDate: Date, createdAt: Date = Date()) {
        self.items = Self.normalize(items)
        self.scanDate = scanDate
        self.createdAt = createdAt
    }

    /// The exact list that may be acted on:
    ///  - only selectable categories (never large personal files),
    ///  - never the same path twice,
    ///  - never an item inside another selected item (it would be counted
    ///    twice and moved with its parent anyway),
    ///  - largest first.
    static func normalize(_ items: [CleanupItem]) -> [CleanupItem] {
        var seen = Set<String>()
        let unique = items.filter { $0.category.isSelectable && seen.insert($0.path).inserted }
        let folders = unique.filter(\.isDirectory).map { $0.path.hasSuffix("/") ? $0.path : $0.path + "/" }
        return unique
            .filter { item in !folders.contains { item.path.hasPrefix($0) } }
            .sorted { $0.size > $1.size }
    }

    var totalSize: UInt64 { items.reduce(0) { $0 + $1.size } }
    var fileCount: Int { items.reduce(0) { $0 + $1.fileCount } }

    /// Items currently in the Trash. Removing them is permanent, so the
    /// confirmation screen asks for a separate, explicit acknowledgement.
    var trashItems: [CleanupItem] { items.filter { $0.category == .trash } }
    var requiresTrashAcknowledgement: Bool { !trashItems.isEmpty }

    var highRiskCount: Int { items.filter { $0.risk == .high }.count }

    /// Per-category totals for the confirmation screen.
    var categories: [(category: CleanupCategory, count: Int, size: UInt64)] {
        CleanupCategory.allCases.compactMap { category in
            let matching = items.filter { $0.category == category }
            guard !matching.isEmpty else { return nil }
            return (category, matching.count, matching.reduce(0) { $0 + $1.size })
        }
    }
}

/// What re-checking an approved item found just before cleanup.
enum ItemVerdict: Sendable, Equatable {
    /// Still exactly as scanned and safe to act on.
    case ready
    /// Gone already (deleted by its app or by you). Nothing to do.
    case missing
    /// Changed since the scan. Skipped; rescan to include it again.
    case changed(String)
    /// Failed a safety rule. Never acted on.
    case rejected(String)

    var isReady: Bool { self == .ready }

    var title: String {
        switch self {
        case .ready: "Ready"
        case .missing: "Already gone"
        case .changed: "Changed since scan"
        case .rejected: "Blocked by a safety rule"
        }
    }

    var detail: String? {
        switch self {
        case .ready, .missing: nil
        case .changed(let why), .rejected(let why): why
        }
    }
}

/// What happened to one approved item.
enum ItemResultKind: Sendable, Equatable {
    /// Moved to the Trash – you can still put it back.
    case movedToTrash
    /// Was already in the Trash and has been deleted for good (you ticked the
    /// separate "permanently deleted" confirmation).
    case deletedPermanently
    /// Failed the re-check (gone, changed or blocked by a safety rule).
    case skipped(ItemVerdict)
    /// A running app has files open inside it; touching it could break that app.
    case inUse(String)
    /// macOS refused the move (e.g. permissions). The message explains why.
    case failed(String)
    /// You pressed Stop before this item was reached.
    case notAttempted

    var isCleaned: Bool { self == .movedToTrash || self == .deletedPermanently }

    var title: String {
        switch self {
        case .movedToTrash: "Moved to Trash"
        case .deletedPermanently: "Deleted permanently"
        case .skipped(let verdict): verdict.title
        case .inUse: "In use – skipped"
        case .failed: "Could not be moved"
        case .notAttempted: "Not attempted (stopped)"
        }
    }

    var detail: String? {
        switch self {
        case .movedToTrash, .deletedPermanently, .notAttempted: nil
        case .skipped(let verdict): verdict.detail
        case .inUse(let apps): "Open in \(apps). Quit it and rescan to clean this item."
        case .failed(let message): message
        }
    }
}

struct ItemResult: Identifiable, Sendable {
    let item: CleanupItem
    let kind: ItemResultKind
    var id: String { item.id }
}

/// Outcome of running a plan (approval step 8).
struct CleanupOutcome: Identifiable, Sendable {
    let id = UUID()
    let plan: CleanupPlan
    let results: [ItemResult]
    /// You pressed Stop part-way through.
    let wasStopped: Bool

    var cleaned: [ItemResult] { results.filter { $0.kind.isCleaned } }
    var notCleaned: [ItemResult] { results.filter { !$0.kind.isCleaned } }
    var freedSize: UInt64 { cleaned.reduce(0) { $0 + $1.item.size } }
    var movedCount: Int { results.filter { $0.kind == .movedToTrash }.count }
    var deletedCount: Int { results.filter { $0.kind == .deletedPermanently }.count }
}

/// Progress while a plan runs.
struct CleanupProgress: Sendable, Equatable {
    var done: Int
    var total: Int
    var currentName: String
}
