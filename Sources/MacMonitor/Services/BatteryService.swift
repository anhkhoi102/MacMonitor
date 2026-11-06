import Foundation
import IOKit

/// Reads the internal battery from the I/O Registry.
///
/// ## Where the numbers come from
/// macOS describes every piece of hardware in the *I/O Registry*. The battery
/// appears as a service called "AppleSmartBattery" whose properties include the
/// charge level, cycle count, voltage and current. You can see the raw data in
/// Terminal with:  `ioreg -rn AppleSmartBattery`
///
/// Reading these properties needs no special permission and changes nothing.
///
/// ## What is not available
/// On recent macOS versions the battery temperature is no longer published to
/// normal apps, so we don't show it rather than guess. Battery health is an
/// estimate (full-charge capacity ÷ design capacity); Apple's figure in System
/// Settings uses its own method and can differ by a few percent.
///
/// It runs on a background thread (`@concurrent`) because I/O Registry
/// lookups can take a few milliseconds.
enum BatteryService {
    @concurrent
    static func sample() async -> BatteryReading {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return .notInstalled }
        // IOKit objects are reference-counted by hand: release when done.
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any]
        else { return .unavailable }

        return makeReading(from: dictionary)
    }

    // MARK: - Pure parsing (unit-tested)

    static func makeReading(from p: [String: Any]) -> BatteryReading {
        if let installed = p["BatteryInstalled"] as? Bool, !installed { return .notInstalled }
        guard let current = int(p["CurrentCapacity"]) else { return .unavailable }

        // On Apple Silicon, CurrentCapacity/MaxCapacity are already percentages.
        let max = int(p["MaxCapacity"]) ?? 100
        let percent = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current

        // Detailed capacities live in the nested "BatteryData" dictionary.
        let data = p["BatteryData"] as? [String: Any] ?? [:]
        let design = int(p["DesignCapacity"]) ?? int(data["DesignCapacity"])
        let full = int(p["AppleRawMaxCapacity"]) ?? int(data["NominalChargeCapacity"]) ?? int(data["FullChargeCapacity"])

        // 65535 means "still calculating".
        let remaining = int(p["TimeRemaining"]).flatMap { $0 > 0 && $0 < 65535 ? $0 : nil }
        let adapter = p["AdapterDetails"] as? [String: Any]

        return .present(BatteryStats(
            percent: min(100, Swift.max(0, percent)),
            isPluggedIn: p["ExternalConnected"] as? Bool ?? false,
            isCharging: p["IsCharging"] as? Bool ?? false,
            isFullyCharged: p["FullyCharged"] as? Bool ?? false,
            minutesRemaining: remaining,
            cycleCount: int(p["CycleCount"]) ?? 0,
            designCapacity: design,
            fullChargeCapacity: full,
            voltage: Double(int(p["Voltage"]) ?? 0) / 1000,                       // mV → V
            amperage: Double(int(p["InstantAmperage"]) ?? int(p["Amperage"]) ?? 0) / 1000,  // mA → A
            adapterWatts: adapter.flatMap { int($0["Watts"]) }
        ))
    }

    /// Registry numbers arrive as NSNumber. Negative values (current while
    /// discharging) are sometimes stored as huge unsigned numbers; reading the
    /// 64-bit pattern as signed turns them back into negatives.
    private static func int(_ value: Any?) -> Int? {
        (value as? NSNumber).map { Int($0.int64Value) }
    }
}
