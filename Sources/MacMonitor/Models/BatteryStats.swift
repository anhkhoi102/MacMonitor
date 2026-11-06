import Foundation

/// A snapshot of the internal battery.
struct BatteryStats: Sendable, Equatable {
    /// Charge level, 0–100.
    var percent: Int
    /// Power adapter connected.
    var isPluggedIn: Bool
    /// Actually charging. Can be false while plugged in, e.g. when macOS
    /// pauses at 80% to protect the battery ("Optimized Charging").
    var isCharging: Bool
    var isFullyCharged: Bool
    /// Minutes until full (charging) or empty (on battery). nil = macOS is
    /// still estimating.
    var minutesRemaining: Int?
    var cycleCount: Int
    /// Capacity when new, in mAh.
    var designCapacity: Int?
    /// What a full charge holds today, in mAh.
    var fullChargeCapacity: Int?
    /// Volts.
    var voltage: Double
    /// Amps; positive while charging, negative on battery.
    var amperage: Double
    /// Watts the adapter is rated for.
    var adapterWatts: Int?

    /// Watts flowing into (+) or out of (−) the battery.
    var power: Double { voltage * amperage }

    /// Today's capacity compared with when new, 0–100. An estimate: Apple's own
    /// "Maximum Capacity" in System Settings uses an unpublished method.
    var estimatedHealth: Double? {
        guard let designCapacity, let fullChargeCapacity, designCapacity > 0 else { return nil }
        return min(100, Double(fullChargeCapacity) / Double(designCapacity) * 100)
    }

    var state: BatteryState {
        if isCharging { return .charging }
        if isPluggedIn { return isFullyCharged ? .charged : .pluggedInNotCharging }
        return .onBattery
    }

    /// SF Symbol matching the charge level.
    var symbolName: String {
        if isCharging { return "battery.100percent.bolt" }
        switch percent {
        case 88...: return "battery.100percent"
        case 63..<88: return "battery.75percent"
        case 38..<63: return "battery.50percent"
        case 13..<38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}

enum BatteryState: Equatable {
    case charging, charged, pluggedInNotCharging, onBattery

    var title: String {
        switch self {
        case .charging: "Charging"
        case .charged: "Fully charged"
        case .pluggedInNotCharging: "Plugged in, not charging"
        case .onBattery: "On battery"
        }
    }
}

/// Result of asking macOS about the battery.
enum BatteryReading: Sendable, Equatable {
    case present(BatteryStats)
    /// This Mac has no battery (e.g. iMac, Mac mini, Mac Studio).
    case notInstalled
    /// The battery exists but could not be read this time.
    case unavailable
}
