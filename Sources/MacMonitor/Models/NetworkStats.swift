import Foundation

/// Real-time network throughput plus running totals.
struct NetworkStats: Sendable, Equatable {
    var downloadBytesPerSecond: Double
    var uploadBytesPerSecond: Double
    /// Bytes received/sent since MacMonitor started.
    var totalDownloaded: UInt64
    var totalUploaded: UInt64
    /// BSD name of the interface macOS uses for internet traffic, e.g. "en0".
    var interfaceName: String
    /// Human-friendly name, e.g. "Wi-Fi" or "USB 10/100/1000 LAN".
    var interfaceType: String
    /// false when macOS has no route to the internet.
    var isConnected = true

    /// SF Symbol for the interface kind.
    var symbolName: String {
        guard isConnected else { return "wifi.slash" }
        if interfaceType == "Wi-Fi" { return "wifi" }
        if interfaceName.hasPrefix("en") { return "cable.connector" }
        if interfaceName.hasPrefix("utun") || interfaceName.hasPrefix("ipsec") { return "lock.shield" }
        return "network"
    }

    static let zero = NetworkStats(downloadBytesPerSecond: 0, uploadBytesPerSecond: 0,
                                   totalDownloaded: 0, totalUploaded: 0,
                                   interfaceName: "—", interfaceType: "—")
}
