import Foundation

/// Small helpers that turn raw numbers into display strings.
/// Keeping them in one place means every screen formats values the same way.
enum Fmt {
    static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    /// Binary gigabytes (1 GB = 1024³ bytes) – the convention Activity Monitor
    /// uses for RAM.
    static func memoryGB(_ bytes: UInt64, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f GB", Double(bytes) / 1_073_741_824)
    }

    /// Per-app memory, like Activity Monitor: "812 MB" or "1.25 GB" (binary units).
    static func appMemory(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        return mb >= 1024 ? String(format: "%.2f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }

    /// "1 h 43 min", or "Calculating…" when macOS has no estimate yet.
    static func duration(minutes: Int?) -> String {
        guard let minutes else { return "Calculating…" }
        let h = minutes / 60, m = minutes % 60
        return h > 0 ? "\(h) h \(m) min" : "\(m) min"
    }

    /// Decimal units (1 GB = 1000³ bytes) – the convention Finder uses for disks.
    static func storage(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }

    /// Network speed in the unit family the user picked in Settings.
    /// Small values switch to KB/s or kbps so they don't show as "0.00".
    static func speed(_ bytesPerSecond: Double, unit: NetworkSpeedUnit) -> String {
        let value = max(0, bytesPerSecond)
        switch unit {
        case .megabytesPerSecond:
            return value >= 1_000_000 ? String(format: "%.2f MB/s", value / 1_000_000)
                                      : String(format: "%.0f KB/s", value / 1_000)
        case .megabitsPerSecond:
            let bits = value * 8
            return bits >= 1_000_000 ? String(format: "%.1f Mbps", bits / 1_000_000)
                                     : String(format: "%.0f kbps", bits / 1_000)
        }
    }
}
