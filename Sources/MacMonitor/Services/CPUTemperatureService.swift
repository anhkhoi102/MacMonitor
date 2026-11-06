import Foundation
import SwiftUI

/// CPU temperature (Overview and CPU page).
///
/// ## Why it shows "Temperature unavailable"
/// macOS has **no public API** for CPU temperature on Apple Silicon. What was
/// investigated (on this M1, macOS 27):
///   - The SMC (System Management Controller) can be read through public
///     IOKit calls, and it does report ~146 temperature sensors. But the
///     sensor key names are undocumented, they changed in this macOS version
///     (the `Tp0x` keys older tools use no longer exist; there are now
///     `Tp/Te/Tc` families with unexplained a/b/x/z variants), and nothing says
///     which one is "the CPU temperature". Showing one of them would risk a
///     plausible-looking but wrong number.
///   - The IOHIDEventSystem route used by some tools relies on private,
///     unexported functions.
///   - `powermetrics` needs administrator rights.
/// So, as required, MacMonitor never shows an estimated or guessed value.
///
/// What macOS *does* provide publicly is the **thermal state**: how hard the
/// system is working to stay cool (Nominal → Critical). It's shown instead,
/// clearly labeled as a state, not a temperature.
enum CPUTemperatureService {
    enum Reading: Equatable {
        case celsius(Double)
        case unavailable(String)
    }

    static let unavailableReason = "macOS has no public way for apps to read CPU temperature on Apple Silicon, and MacMonitor doesn't show guessed values."

    static func read() -> Reading { .unavailable(unavailableReason) }

    static func thermalState() -> ProcessInfo.ThermalState { ProcessInfo.processInfo.thermalState }
}

extension ProcessInfo.ThermalState {
    var title: String {
        switch self {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }

    var color: Color {
        switch self {
        case .nominal: .green
        case .fair: .yellow
        case .serious: .orange
        case .critical: .red
        @unknown default: .gray
        }
    }

    var explanation: String {
        switch self {
        case .nominal: "Running cool. No action needed."
        case .fair: "Slightly warm. macOS may start managing heat."
        case .serious: "Hot. macOS is slowing things down to cool off."
        case .critical: "Very hot. Performance is heavily reduced to protect the Mac."
        @unknown default: "macOS reported an unknown state."
        }
    }
}
