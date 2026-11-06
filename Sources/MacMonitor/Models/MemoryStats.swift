import SwiftUI

/// A snapshot of physical memory, in bytes.
///
/// macOS deliberately keeps "free" RAM low by using spare memory as file cache,
/// so `total - free` would make the Mac look almost full all the time.
/// Instead we follow Activity Monitor's model:
///
///   used      = app memory + wired + compressed
///   cached    = file-backed pages macOS can drop instantly when needed
///   available = total - used   (free + cached)
///
/// *Utilization* (how much is in use) and *pressure* (how hard the system is
/// working to satisfy memory demand) are different things: you can be at 90%
/// utilization with green pressure thanks to caching and compression.
struct MemoryStats: Sendable, Equatable {
    var total: UInt64
    var appMemory: UInt64
    var wired: UInt64
    var compressed: UInt64
    var cached: UInt64
    var pressure: MemoryPressure
    /// 0–100, how strained the memory system is (100 − the kernel's "available %").
    var pressurePercent: Double
    /// Memory pages currently written out to the SSD.
    var swapUsed: UInt64 = 0
    /// Size of the swap files macOS has created so far (grows on demand).
    var swapTotal: UInt64 = 0
    /// Pages not used for anything at all.
    var free: UInt64 = 0

    var used: UInt64 { appMemory + wired + compressed }
    var available: UInt64 { total > used ? total - used : 0 }
    var utilization: Double { total == 0 ? 0 : Double(used) / Double(total) * 100 }

    /// Memory in states not listed above (e.g. pages the kernel is in the
    /// middle of moving). Whatever is left after the known categories.
    var other: UInt64 {
        let known = used + cached + free
        return total > known ? total - known : 0
    }

    /// Every type of memory, adding up to `total`. Used by "Memory by Type".
    var segments: [MemorySegment] {
        [
            MemorySegment(id: "app", title: "App Memory", bytes: appMemory, color: .purple,
                          detail: "Memory apps asked for and are using right now."),
            MemorySegment(id: "wired", title: "Wired", bytes: wired, color: .orange,
                          detail: "Locked by macOS itself; can never be compressed or moved out."),
            MemorySegment(id: "compressed", title: "Compressed", bytes: compressed, color: .pink,
                          detail: "App memory squeezed to save space instead of using swap."),
            MemorySegment(id: "cached", title: "Cached Files", bytes: cached, color: .teal,
                          detail: "Copies of recently used files. Freed instantly when needed."),
            MemorySegment(id: "free", title: "Free", bytes: free, color: .green,
                          detail: "Completely unused. macOS keeps this small on purpose."),
            MemorySegment(id: "other", title: "Other", bytes: other, color: .gray,
                          detail: "Pages in transition between the states above."),
        ]
    }

    static let zero = MemoryStats(total: 0, appMemory: 0, wired: 0, compressed: 0,
                                  cached: 0, pressure: .normal, pressurePercent: 0)
}

/// The three memory-pressure levels macOS reports.
enum MemoryPressure: String, Sendable, Equatable {
    case normal, warning, critical

    var title: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }

    var color: Color {
        switch self {
        case .normal: .green
        case .warning: .yellow
        case .critical: .red
        }
    }
}

/// One slice of "Memory by Type".
struct MemorySegment: Identifiable, Equatable {
    let id: String
    let title: String
    let bytes: UInt64
    let color: Color
    let detail: String
}
