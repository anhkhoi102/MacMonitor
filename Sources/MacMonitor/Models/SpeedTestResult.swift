import Foundation

/// Outcome of one Internet speed test.
struct SpeedTestResult: Codable, Sendable, Equatable {
    var downloadMbps: Double
    var uploadMbps: Double
    /// Idle latency: how long a tiny request takes to get a reply.
    var pingMs: Double
    /// How much that latency varies from one request to the next.
    var jitterMs: Double
    /// Cloudflare data-center code, e.g. "SJC".
    var serverCode: String
    /// Readable location, e.g. "San Jose" (nil if the code is unknown).
    var serverCity: String?
    var date: Date
    /// Data the test transferred (download + upload), in bytes.
    var bytesTransferred: Int64

    var serverDescription: String {
        serverCity.map { "Cloudflare · \($0) (\(serverCode))" } ?? "Cloudflare · \(serverCode)"
    }
}

/// Which part of the test is running.
enum SpeedTestPhase: String, Sendable, Equatable {
    case connecting = "Connecting"
    case latency = "Measuring ping"
    case download = "Testing download"
    case upload = "Testing upload"
}

/// Progress update sent to the UI while a test runs.
struct SpeedTestProgress: Sendable, Equatable {
    var phase: SpeedTestPhase
    /// 0–1 across the whole test.
    var fraction: Double
    /// Speed of the most recent transfer, for the live readout.
    var currentMbps: Double?
}

/// What the Speed Test card shows.
enum SpeedTestState: Equatable {
    case idle
    case running(SpeedTestProgress)
    case failed(String)
    case cancelled
}
