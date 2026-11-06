import ServiceManagement

/// "Open MacMonitor when I log in" (Phase 11), using Apple's ServiceManagement
/// framework. Off by default; only changes when you flip the switch.
///
/// macOS stores this itself (System Settings › General › Login Items), so we
/// always read the real status instead of keeping our own copy.
///
/// Limits: it needs the packaged MacMonitor.app (not `swift run`). macOS works
/// best with apps in /Applications; for an ad-hoc-signed app it may ask you to
/// approve the item in System Settings.
@MainActor
enum LaunchAtLogin {
    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isEnabled: Bool { status == .enabled }
    static var needsApproval: Bool { status == .requiresApproval }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// Opens System Settings › General › Login Items.
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
