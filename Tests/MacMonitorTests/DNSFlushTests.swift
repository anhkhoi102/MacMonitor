import Foundation
import Testing
@testable import MacMonitor

struct DNSFlushTests {
    @Test func commandIsFixedAndMinimal() {
        // Exactly Apple's two documented commands, by absolute path. Nothing else.
        #expect(DNSFlushService.command == "/usr/bin/dscacheutil -flushcache && /usr/bin/killall -HUP mDNSResponder")
        #expect(!DNSFlushService.command.contains("sudo"))
        #expect(!DNSFlushService.command.contains("rm "))
        #expect(DNSFlushService.appleScript.contains("with administrator privileges"))
        #expect(DNSFlushService.appleScript.contains(DNSFlushService.command))
        #expect(!DNSFlushService.appleScript.contains("password \""))   // no stored password
    }

    @Test func parsesOutcomes() {
        #expect(DNSFlushService.outcome(status: 0, errorOutput: "") == .flushed)
        #expect(DNSFlushService.outcome(status: 1, errorOutput: "0:120: execution error: User canceled. (-128)\n") == .cancelled)
        guard case .failed(let message) = DNSFlushService.outcome(status: 1, errorOutput: "0:9: execution error: The command exited with a non-zero status. (1)\n")
        else { Issue.record("expected failure"); return }
        #expect(message == "The command exited with a non-zero status. (1)")
        guard case .failed = DNSFlushService.outcome(status: 1, errorOutput: "") else { Issue.record("must not claim success"); return }
    }

    /// Real osascript errors in the same format the admin dialog produces –
    /// without asking for any privileges.
    @Test func realOsascriptErrorsAreUnderstood() throws {
        func run(_ script: String) throws -> DNSFlushService.Outcome {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            let pipe = Pipe()
            process.standardError = pipe
            process.standardOutput = Pipe()
            try process.run()
            process.waitUntilExit()
            return DNSFlushService.outcome(status: process.terminationStatus,
                                           errorOutput: String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        #expect(try run("error \"User canceled.\" number -128") == .cancelled)
        guard case .failed = try run("do shell script \"/usr/bin/false\"") else { Issue.record("expected failure"); return }
        #expect(try run("do shell script \"/usr/bin/true\"") == .flushed)
    }
}
