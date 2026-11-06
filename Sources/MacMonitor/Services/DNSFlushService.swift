import Foundation

/// "Flush DNS Cache" (Network page).
///
/// ## What it does
/// macOS keeps recent DNS answers (name → IP address) in a local cache.
/// Flushing it makes the Mac look names up again, which can fix sites that
/// moved or stale entries after changing networks or VPNs. Apple's documented
/// way is two commands:
///
///     dscacheutil -flushcache          clears the Directory Services cache
///     killall -HUP mDNSResponder       tells the DNS resolver to drop its cache
///
/// ## Why it asks for your password
/// The resolver (`mDNSResponder`) runs as a system user, so only an
/// administrator may signal it (tested: as a normal user `killall` fails with
/// "No matching processes belonging to you"). MacMonitor therefore asks macOS
/// to run the two fixed commands with administrator rights through
/// AppleScript's `with administrator privileges`, which shows the standard
/// macOS password / Touch ID dialog. Your password goes to macOS, never to
/// MacMonitor, and nothing is stored.
///
/// ## Safety
///   - The command text is a constant with absolute paths. Nothing from user
///     input or anywhere else is ever inserted into it.
///   - No `sudo`, no stored or hard-coded password.
///   - It only runs after the user confirms, in a separate process, so the
///     app never freezes.
///   - Success is reported only if macOS says both commands succeeded.
enum DNSFlushService {
    enum Outcome: Equatable {
        case flushed
        case cancelled
        case failed(String)
    }

    /// The only command this feature can ever run (as administrator).
    static let command = "/usr/bin/dscacheutil -flushcache && /usr/bin/killall -HUP mDNSResponder"

    /// AppleScript that asks macOS for administrator approval, then runs `command`.
    static let appleScript =
        "do shell script \"\(command)\" with prompt \"MacMonitor wants to flush the DNS cache.\" with administrator privileges"

    @concurrent
    static func flush() async -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                do { try process.run() } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } catch {
            return .failed("Couldn't start the macOS authorization helper: \(error.localizedDescription)")
        }
        let message = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return outcome(status: process.terminationStatus, errorOutput: message)
    }

    /// Turns osascript's exit status and error text into a result. Pure, so it is unit-tested.
    static func outcome(status: Int32, errorOutput: String) -> Outcome {
        if status == 0 { return .flushed }
        if errorOutput.contains("(-128)") || errorOutput.localizedCaseInsensitiveContains("User canceled") {
            return .cancelled
        }
        if errorOutput.contains("(-60005)") || errorOutput.contains("(-60007)") {
            return .failed("macOS didn't grant administrator rights. Only an administrator account can flush the DNS cache.")
        }
        let detail = errorOutput
            .replacingOccurrences(of: #"^\d+:\d+: execution error: "#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(detail.isEmpty ? "The flush command failed (exit status \(status))." : detail)
    }
}
