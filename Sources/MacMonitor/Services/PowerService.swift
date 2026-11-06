import AppKit
import CoreServices
import Darwin

/// Restart, Shut Down, Sleep and Lock Screen (Power page).
///
/// None of these need administrator rights, and none bypass anything:
///
/// - **Restart / Shut Down** send Apple's documented Apple Events
///   (`kAERestart` / `kAEShutDown`) to `loginwindow` – the same request the
///   Apple menu makes. macOS asks every open app to quit first, so apps can
///   ask to save your work, and any app can cancel the restart.
///   macOS may ask once for permission ("MacMonitor wants to control
///   loginwindow") under Privacy & Security › Automation.
/// - **Sleep** runs `pmset sleepnow` (Apple's power tool, no admin needed),
///   falling back to the `kAESleep` Apple Event.
/// - **Lock Screen** calls `SACLockScreenImmediate` from macOS's own login
///   framework – what the Apple menu's "Lock Screen" item uses. ⚠️ This is a
///   **private, undocumented** function: there is no public API that locks
///   immediately (display sleep only locks after your "Require password"
///   delay, e.g. 5 minutes). It's looked up at runtime; if a future
///   macOS removes it, the Lock button hides itself instead of failing.
@MainActor
enum PowerService {
    enum Action: String, CaseIterable, Identifiable {
        case restart = "Restart"
        case shutDown = "Shut Down"
        case sleep = "Sleep"
        case lock = "Lock Screen"
        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .restart: "arrow.clockwise.circle"
            case .shutDown: "power"
            case .sleep: "moon.zzz"
            case .lock: "lock"
            }
        }

        /// Restart and Shut Down end your session, so they ask first.
        var needsConfirmation: Bool { self == .restart || self == .shutDown }

        var explanation: String {
            switch self {
            case .restart: "macOS asks every open app to quit (apps may ask you to save), then restarts. Any app can cancel it."
            case .shutDown: "macOS asks every open app to quit (apps may ask you to save), then turns the Mac off. Any app can cancel it."
            case .sleep: "Puts the Mac to sleep right away. Press a key or open the lid to wake it."
            case .lock: "Locks the screen immediately. Apps keep running; unlock with your password or Touch ID."
            }
        }
    }

    /// Lock Screen is offered only if macOS still provides the function.
    static var isLockAvailable: Bool { lockFunction != nil }

    /// Performs the action. Returns an error message, or nil on success.
    static func perform(_ action: Action) -> String? {
        switch action {
        case .restart: return sendToLoginWindow(AEEventID(kAERestart))
        case .shutDown: return sendToLoginWindow(AEEventID(kAEShutDown))
        case .sleep:
            if runPmsetSleep() { return nil }
            return sendToLoginWindow(AEEventID(kAESleep))
        case .lock:
            guard let lock = lockFunction else { return "Lock Screen isn't available on this version of macOS." }
            _ = lock()
            return nil
        }
    }

    // MARK: Implementation

    private typealias LockFunction = @convention(c) () -> Int32

    private static let lockFunction: LockFunction? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
              let symbol = dlsym(handle, "SACLockScreenImmediate") else { return nil }
        return unsafeBitCast(symbol, to: LockFunction.self)
    }()

    private static func sendToLoginWindow(_ eventID: AEEventID) -> String? {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.loginwindow")
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: eventID,
                                           targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        do {
            _ = try event.sendEvent(options: [.noReply], timeout: 10)
            return nil
        } catch {
            return message(forAppleEventError: (error as NSError).code)
        }
    }

    static func message(forAppleEventError code: Int) -> String {
        switch code {
        case -1743, -1744:
            "macOS blocked the request. Allow MacMonitor to control “loginwindow” in System Settings › Privacy & Security › Automation, then try again."
        case -600:
            "macOS's login window process isn't responding. Try again, or use the Apple menu."
        default:
            "macOS didn't accept the request (error \(code)). Use the Apple menu instead."
        }
    }

    private static func runPmsetSleep() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["sleepnow"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
