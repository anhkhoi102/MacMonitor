import Foundation

/// One macOS release from Apple's software update catalog.
struct MacOSRelease: Codable, Sendable, Equatable {
    var version: String
    var build: String
    var postingDate: Date?
}

/// Security content of one macOS update, summarized from Apple Security Releases.
struct SecurityRelease: Codable, Sendable, Equatable {
    /// e.g. "macOS Golden Gate 27.2"
    var title: String
    var version: String
    var releaseDate: String
    var url: String?
    /// Number of distinct issues Apple lists (one per "Impact").
    var issueCount: Int
    var cveIDs: [String]
    var groups: [ImpactGroup]
    /// Apple says some issue "may have been exploited" / was actively exploited.
    var exploitedInTheWild: Bool
}

/// Issues of the same kind, e.g. all "may lead to arbitrary code execution".
struct ImpactGroup: Codable, Sendable, Equatable, Identifiable {
    var category: ImpactCategory
    var count: Int
    var example: String
    var cveIDs: [String]
    var id: String { category.rawValue }
}

enum ImpactCategory: String, Codable, Sendable, CaseIterable {
    case exploited = "Actively exploited"
    case codeExecution = "Code execution"
    case privilegeEscalation = "Privilege escalation"
    case securityBypass = "Security bypass"
    case privacy = "Privacy and data access"
    case crash = "Crashes and denial of service"
    case other = "Other"
}

/// How urgently to update (the classification from the spec).
enum UpdatePriority: String, Codable, Sendable {
    case critical = "Critical", high = "High", medium = "Medium", low = "Low"

    var meaning: String {
        switch self {
        case .critical: "Important security vulnerabilities or serious system risks. Update as soon as possible."
        case .high: "Significant security fixes, major bugs or stability improvements. Update recommended."
        case .medium: "General bug fixes, compatibility improvements and performance enhancements."
        case .low: "Minor improvements without significant security or operational impact."
        }
    }
}

/// Everything fetched from Apple, cached on disk.
struct MacOSUpdateInfo: Codable, Sendable, Equatable {
    /// Newest macOS Apple has released, for any Mac.
    var latestReleased: MacOSRelease?
    /// Newest macOS Apple lists as supported on *this* Mac's board ID.
    var latestCompatible: MacOSRelease?
    /// Major version → marketing name (e.g. "27" → "Golden Gate"), from Apple's security page.
    var releaseNames: [String: String]
    /// Security content of releases newer than the installed version, newest first.
    var securityReleases: [SecurityRelease]
    var fetchedAt: Date
    /// Board ID and installed version these results were computed for.
    var boardID: String
    var installedVersion: String
}
