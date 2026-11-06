import Foundation
import os

/// Internet speed test using Cloudflare's public speed-test endpoints (Phase 7).
///
/// It only runs when the user presses "Run Speed Test" – never automatically.
///
/// ## Endpoints (the same ones speed.cloudflare.com and Cloudflare's
/// open-source speed-test library use)
///   - `GET  https://speed.cloudflare.com/__down?bytes=N` → sends back N bytes
///   - `POST https://speed.cloudflare.com/__up`           → accepts an upload
///
/// ## Method
/// 1. **Ping & jitter.** 20 tiny requests over one open connection. For each:
///    time-to-first-byte minus Cloudflare's own processing time (reported in
///    the `Server-Timing` header). Ping = median, jitter = average change
///    between consecutive samples (the definition Cloudflare uses).
/// 2. **Download.** Transfers that start at 100 KB and grow 4× until one takes
///    about a second (max 50 MB each), within a 150 MB / 10 s budget. Speed =
///    bytes × 8 ÷ transfer time. Short transfers are dominated by start-up
///    effects, so only those lasting ≥ 0.2 s count. Result = 90th percentile.
/// 3. **Upload.** Same idea with POST requests (max 25 MB each, 60 MB / 10 s).
///    Here the duration comes from Cloudflare's `cfSpeedWorker` timing, which
///    is how long the server spent *receiving* the body. (Our own clock can't
///    tell: the reply time doesn't show when the last byte arrived.)
///
/// Timing comes from `URLSessionTaskMetrics`, which records exactly when each
/// request started and when the response began and ended, rather than
/// stopwatch times that would include our own app's overhead.
///
/// Note: this measures a single connection, like Cloudflare's own test.
/// Very fast lines (> ~500 Mbps) may score lower than multi-connection tests.
enum SpeedTestService {
    static let baseURL = URL(string: "https://speed.cloudflare.com")!

    struct Limits: Sendable {
        var latencySamples = 20
        var downloadBudgetBytes = 150_000_000
        var downloadMaxTransfer = 50_000_000
        var uploadBudgetBytes = 60_000_000
        var uploadMaxTransfer = 25_000_000
        var phaseTimeLimit: Duration = .seconds(10)
    }

    typealias ProgressHandler = @Sendable (SpeedTestProgress) async -> Void

    /// Runs a full test. Throws `CancellationError` if the calling task is
    /// canceled, or `SpeedTestError` for network problems.
    @concurrent
    static func run(limits: Limits = Limits(), progress: ProgressHandler) async throws -> SpeedTestResult {
        let configuration = URLSessionConfiguration.ephemeral   // no cookies, no cache on disk
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.httpMaximumConnectionsPerHost = 1          // reuse one connection
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        do {
            // 1. Connect (opens the connection so it isn't counted in ping).
            await progress(SpeedTestProgress(phase: .connecting, fraction: 0))
            let warmUp = try await request(session, download: 0)
            let serverCode = coloCode(fromRay: warmUp.rayHeader) ?? "?"

            // 2. Ping and jitter.
            var latencies: [Double] = []
            for i in 0..<limits.latencySamples {
                try Task.checkCancellation()
                let sample = try await request(session, download: 0)
                latencies.append(sample.latencyMs)
                await progress(SpeedTestProgress(phase: .latency,
                                                 fraction: 0.1 * Double(i + 1) / Double(limits.latencySamples)))
            }
            let ping = median(latencies)
            let jitter = Self.jitter(latencies)

            // 3. Download.
            var transferred: Int64 = 0
            let download = try await measureThroughput(
                maxTransfer: limits.downloadMaxTransfer, budget: limits.downloadBudgetBytes,
                timeLimit: limits.phaseTimeLimit, pingMs: ping,
                run: { size in try await request(session, download: size) },
                report: { fraction, mbps in
                    await progress(SpeedTestProgress(phase: .download, fraction: 0.1 + 0.45 * fraction, currentMbps: mbps))
                })
            transferred += Int64(download.bytes)

            // 4. Upload.
            let uploadBody = randomData(count: limits.uploadMaxTransfer)
            let upload = try await measureThroughput(
                maxTransfer: limits.uploadMaxTransfer, budget: limits.uploadBudgetBytes,
                timeLimit: limits.phaseTimeLimit, pingMs: ping,
                run: { size in try await request(session, upload: uploadBody.prefix(size)) },
                report: { fraction, mbps in
                    await progress(SpeedTestProgress(phase: .upload, fraction: 0.55 + 0.45 * fraction, currentMbps: mbps))
                })
            transferred += Int64(upload.bytes)

            return SpeedTestResult(downloadMbps: download.mbps, uploadMbps: upload.mbps,
                                   pingMs: ping, jitterMs: jitter,
                                   serverCode: serverCode, serverCity: cityNames[serverCode],
                                   date: Date(), bytesTransferred: transferred)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw SpeedTestError(urlError: error)
        }
    }

    // MARK: - Throughput phase

    private static func measureThroughput(
        maxTransfer: Int, budget: Int, timeLimit: Duration, pingMs: Double,
        run: (Int) async throws -> Measurement,
        report: (Double, Double?) async -> Void
    ) async throws -> (mbps: Double, bytes: Int) {
        let start = ContinuousClock.now
        var size = 100_000
        var used = 0
        var samples: [Double] = []
        var allSamples: [Double] = []

        while used + size <= budget, ContinuousClock.now - start < timeLimit {
            try Task.checkCancellation()
            let m = try await run(size)
            used += size
            let seconds = m.isUpload
                ? uploadSeconds(serverMs: m.serverMs, roundTripSeconds: m.transferSeconds, pingMs: pingMs)
                : m.transferSeconds
            let mbps = Self.mbps(bytes: size, seconds: seconds)
            allSamples.append(mbps)
            if seconds >= 0.2 { samples.append(mbps) }

            let elapsed = ContinuousClock.now - start
            await report(min(1, max(Double(used) / Double(budget), elapsed / timeLimit)), mbps)
            size = nextTransferSize(current: size, lastSeconds: seconds, max: maxTransfer)
        }
        let result = percentile(samples.isEmpty ? allSamples : samples, 0.9)
        await report(1, result)
        return (result, used)
    }

    // MARK: - Single requests

    /// Timing of one request, from URLSessionTaskMetrics.
    struct Measurement: Sendable {
        var latencyMs: Double        // time to first byte − server processing
        var transferSeconds: Double  // download: body received; upload: request start → reply
        var serverMs: Double         // Cloudflare's Server-Timing value
        var rayHeader: String?
        var isUpload: Bool
    }

    private static func request(_ session: URLSession, download bytes: Int) async throws -> Measurement {
        var request = URLRequest(url: baseURL.appending(path: "__down").appending(queryItems: [URLQueryItem(name: "bytes", value: String(bytes))]))
        request.httpMethod = "GET"
        let collector = MetricsCollector()
        let (_, response) = try await session.data(for: request, delegate: collector)
        return try measurement(response, collector.timing, isUpload: false)
    }

    private static func request(_ session: URLSession, upload body: Data) async throws -> Measurement {
        var request = URLRequest(url: baseURL.appending(path: "__up"))
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let collector = MetricsCollector()
        let (_, response) = try await session.upload(for: request, from: body, delegate: collector)
        return try measurement(response, collector.timing, isUpload: true)
    }

    private static func measurement(_ response: URLResponse, _ timing: Timing?, isUpload: Bool) throws -> Measurement {
        guard let http = response as? HTTPURLResponse else { throw SpeedTestError.unexpectedResponse }
        guard http.statusCode == 200 else { throw SpeedTestError.server(status: http.statusCode) }
        guard let timing, let requestStart = timing.requestStart, let responseStart = timing.responseStart,
              let responseEnd = timing.responseEnd
        else { throw SpeedTestError.unexpectedResponse }

        let serverMs = serverProcessingMs(http.value(forHTTPHeaderField: "Server-Timing"))
        let ttfbMs = responseStart.timeIntervalSince(requestStart) * 1000
        let transfer = isUpload
            ? responseStart.timeIntervalSince(requestStart)   // whole upload + reply
            : responseEnd.timeIntervalSince(responseStart)    // body received
        return Measurement(latencyMs: max(0, ttfbMs - serverMs),
                           transferSeconds: max(0.000_1, transfer),
                           serverMs: serverMs,
                           rayHeader: http.value(forHTTPHeaderField: "CF-RAY"),
                           isUpload: isUpload)
    }

    // MARK: - Pure helpers (unit-tested)

    static func mbps(bytes: Int, seconds: Double) -> Double {
        seconds > 0 ? Double(bytes) * 8 / seconds / 1_000_000 : 0
    }

    /// How long an upload took. Prefer the server's own receive time; if the
    /// header is missing, use our round-trip time minus one ping.
    static func uploadSeconds(serverMs: Double, roundTripSeconds: Double, pingMs: Double) -> Double {
        if serverMs > 0 { return serverMs / 1000 }
        return max(0.001, roundTripSeconds - pingMs / 1000)
    }

    /// Grow 4× while transfers finish quickly, so each phase reaches transfers
    /// long enough (~1 s) to measure steady speed.
    static func nextTransferSize(current: Int, lastSeconds: Double, max maximum: Int) -> Int {
        lastSeconds < 0.8 ? min(current * 4, maximum) : current
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// Average absolute difference between consecutive samples.
    static func jitter(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let diffs = zip(values, values.dropFirst()).map { abs($1 - $0) }
        return diffs.reduce(0, +) / Double(diffs.count)
    }

    /// Linear-interpolated percentile, p in 0…1.
    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let position = p * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down)), upper = Int(position.rounded(.up))
        let weight = position - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }

    /// Server processing time from e.g. "cfSpeedEdge;dur=2, cfSpeedWorker;dur=19".
    /// The two stages may overlap, so the larger value is used.
    static func serverProcessingMs(_ header: String?) -> Double {
        guard let header else { return 0 }
        var longest = 0.0
        for entry in header.split(separator: ",") where entry.contains("cfSpeed") || entry.contains("cfRequestDuration") {
            for part in entry.split(separator: ";") {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("dur="), let value = Double(trimmed.dropFirst(4)) {
                    longest = max(longest, value)
                }
            }
        }
        return longest
    }

    /// "8f2b1c0a4f6eddc5-SJC" → "SJC".
    static func coloCode(fromRay ray: String?) -> String? {
        guard let ray, let dash = ray.lastIndex(of: "-") else { return nil }
        let code = ray[ray.index(after: dash)...]
        return code.count == 3 && code.allSatisfy(\.isLetter) ? code.uppercased() : nil
    }

    private static func randomData(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        var data = Data(count: count)
        data.withUnsafeMutableBytes { raw in
            let words = raw.bindMemory(to: UInt64.self)
            for i in words.indices { words[i] = generator.next() }
        }
        return data
    }

    /// A few common Cloudflare locations. Unknown codes just show the code.
    static let cityNames: [String: String] = [
        "HKG": "Hong Kong", "SIN": "Singapore", "SGN": "Ho Chi Minh City", "HAN": "Hanoi",
        "BKK": "Bangkok", "KUL": "Kuala Lumpur", "CGK": "Jakarta", "MNL": "Manila",
        "TPE": "Taipei", "NRT": "Tokyo", "KIX": "Osaka", "ICN": "Seoul", "SYD": "Sydney",
        "MEL": "Melbourne", "BOM": "Mumbai", "DEL": "New Delhi", "DXB": "Dubai",
        "LHR": "London", "FRA": "Frankfurt", "AMS": "Amsterdam", "CDG": "Paris",
        "MAD": "Madrid", "LAX": "Los Angeles", "SJC": "San Jose", "SEA": "Seattle",
        "ORD": "Chicago", "DFW": "Dallas", "IAD": "Ashburn", "EWR": "Newark",
        "ATL": "Atlanta", "MIA": "Miami", "YYZ": "Toronto", "GRU": "São Paulo",
    ]
}

// MARK: - Metrics collection

/// Timestamps of one request. Only `Date`s, so it can safely cross threads.
struct Timing: Sendable {
    var requestStart: Date?
    var responseStart: Date?
    var responseEnd: Date?
}

/// Receives URLSession's precise timing for one request.
/// URLSession may call it on any thread, so the stored value is protected
/// by a lock – that is what makes the class `Sendable`.
final class MetricsCollector: NSObject, URLSessionTaskDelegate, Sendable {
    private let state = OSAllocatedUnfairLock<Timing?>(initialState: nil)

    var timing: Timing? { state.withLock { $0 } }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let last = metrics.transactionMetrics.last else { return }
        let timing = Timing(requestStart: last.requestStartDate,
                            responseStart: last.responseStartDate,
                            responseEnd: last.responseEndDate)
        state.withLock { $0 = timing }
    }
}

// MARK: - Errors

enum SpeedTestError: LocalizedError, Equatable {
    case offline
    case timedOut
    case cannotReachServer
    case server(status: Int)
    case unexpectedResponse
    case other(String)

    init(urlError: URLError) {
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            self = .offline
        case .timedOut:
            self = .timedOut
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .secureConnectionFailed, .serverCertificateUntrusted:
            self = .cannotReachServer
        default:
            self = .other(urlError.localizedDescription)
        }
    }

    var errorDescription: String? {
        switch self {
        case .offline: "You appear to be offline. Check your Wi-Fi or Ethernet connection and try again."
        case .timedOut: "The connection is too slow or stopped responding. Try again in a moment."
        case .cannotReachServer: "Couldn't reach Cloudflare's speed-test server. A firewall, VPN or DNS problem may be blocking it."
        case .server(let status): "Cloudflare's server returned an error (HTTP \(status)). Try again later."
        case .unexpectedResponse: "The server sent an unexpected response. Try again."
        case .other(let message): message
        }
    }
}
