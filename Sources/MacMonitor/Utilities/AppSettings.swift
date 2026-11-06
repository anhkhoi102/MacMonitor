import SwiftUI
import AppKit

/// Keys used to store preferences in UserDefaults (via @AppStorage).
/// Preferences live in ~/Library/Preferences/<bundle id>.plist.
enum SettingsKey {
    static let appearance = "appearance"
    static let cpuInterval = "cpuRefreshInterval"
    static let memoryInterval = "memoryRefreshInterval"
    static let networkInterval = "networkRefreshInterval"
    static let diskInterval = "diskRefreshInterval"
    static let historySeconds = "historySeconds"
    static let speedUnit = "networkSpeedUnit"
}

/// Light / Dark / follow the system.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    static var current: AppearanceMode {
        AppearanceMode(rawValue: UserDefaults.standard.string(forKey: SettingsKey.appearance) ?? "") ?? .system
    }

    /// Setting `NSApp.appearance` is the most reliable way to switch the whole
    /// app (including the sidebar and title bar). `nil` means "follow macOS".
    @MainActor
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

enum NetworkSpeedUnit: String, CaseIterable, Identifiable {
    case megabytesPerSecond, megabitsPerSecond
    var id: String { rawValue }
    var title: String { self == .megabytesPerSecond ? "MB/s" : "Mbps" }
}

/// Default values used when the user has not changed a setting yet.
enum SettingsDefaults {
    static let cpuInterval = 1.0
    static let memoryInterval = 2.0
    static let networkInterval = 1.0
    static let diskInterval = 10.0
    static let historySeconds = 120
}
