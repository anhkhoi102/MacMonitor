import SwiftUI

struct BatteryView: View {
    @Environment(DashboardViewModel.self) private var vm

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Battery", subtitle: "Charge, health and power")

                if let battery = vm.battery {
                    content(battery)
                } else if vm.hasBattery == false {
                    ContentUnavailableView("No Battery", systemImage: "powerplug",
                                           description: Text("This Mac runs on AC power only."))
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    ProgressView("Reading battery…")
                        .frame(maxWidth: .infinity, minHeight: 300)
                }

                // Shown on every Mac, with or without a battery.
                SystemUptimeCard()
            }
            .padding(24)
        }
    }

    @ViewBuilder
    private func content(_ b: BatteryStats) -> some View {
        HStack(spacing: 12) {
            StatTile(title: "Charge", value: "\(b.percent)%", systemImage: b.symbolName, tint: chargeColor(b))
            StatTile(title: "Status", value: b.state.title, systemImage: b.isPluggedIn ? "powerplug.fill" : "bolt.slash", tint: .green)
            StatTile(title: b.isCharging ? "Until full" : "Time left", value: Fmt.duration(minutes: b.minutesRemaining),
                     systemImage: "clock", tint: .blue)
            StatTile(title: b.power >= 0 ? "Charging power" : "Power draw",
                     value: String(format: "%.1f W", abs(b.power)), systemImage: "bolt.fill", tint: .orange)
        }

        HStack(alignment: .top, spacing: 16) {
            Card(title: "Charge", systemImage: b.symbolName, tint: chargeColor(b)) {
                HStack(spacing: 20) {
                    RingGauge(value: Double(b.percent), tint: chargeColor(b), size: 110, caption: b.state.title)
                    VStack(alignment: .leading, spacing: 8) {
                        StatRow(label: "Power adapter", value: b.isPluggedIn ? (b.adapterWatts.map { "\($0) W" } ?? "Connected") : "Not connected")
                        StatRow(label: b.isCharging ? "Time until full" : "Time remaining",
                                value: Fmt.duration(minutes: b.minutesRemaining))
                        if b.state == .pluggedInNotCharging {
                            Text("macOS may pause charging (e.g. at 80%) to protect the battery – this is normal.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            Card(title: "Health", systemImage: "heart.fill", tint: .pink) {
                if let health = b.estimatedHealth {
                    HStack(alignment: .firstTextBaseline) {
                        Text(String(format: "%.0f%%", health))
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                        Text("estimated capacity vs. new").foregroundStyle(.secondary)
                    }
                    UsageBar(value: health, tint: .pink, height: 8)
                }
                VStack(spacing: 6) {
                    StatRow(label: "Cycle count", value: "\(b.cycleCount)")
                    if let full = b.fullChargeCapacity, let design = b.designCapacity {
                        StatRow(label: "Full charge holds", value: "\(full) mAh of \(design) mAh")
                    }
                }
                Text("An estimate: System Settings › Battery calculates “Maximum Capacity” with Apple's own method and may show a few percent more or less. MacBook batteries are designed for 1,000 cycles.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        Card(title: "Electrical", systemImage: "bolt.horizontal.fill", tint: .orange) {
            HStack(spacing: 32) {
                StatRow(label: "Voltage", value: String(format: "%.2f V", b.voltage))
                StatRow(label: "Current", value: String(format: "%+.2f A", b.amperage))
                StatRow(label: "Power", value: String(format: "%+.1f W", b.power))
            }
            Text("Positive = flowing into the battery, negative = the Mac is running on it. Updated every 10 seconds. Battery temperature is not shown because recent macOS versions no longer share it with apps.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func chargeColor(_ b: BatteryStats) -> Color {
        if b.isCharging || b.isPluggedIn { return .green }
        return b.percent <= 10 ? .red : b.percent <= 20 ? .orange : .green
    }
}

/// "System Uptime": time since the Mac last started, and when that was.
struct SystemUptimeCard: View {
    /// Read once: the boot time only changes when the Mac restarts.
    @ViewState private var bootDate = SystemUptimeService.bootDate()

    var body: some View {
        Card(title: "System Uptime", systemImage: "clock.arrow.circlepath", tint: .indigo) {
            if let bootDate {
                // Re-draws every 30 seconds; nothing runs while the page is hidden.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(SystemUptimeService.formatUptime(from: bootDate, to: context.date))
                            .font(.system(size: 24, weight: .semibold, design: .rounded))
                        StatRow(label: "Last boot",
                                value: bootDate.formatted(.dateTime.day().month(.wide).year().hour().minute()))
                    }
                }
                Text("Time since macOS last started (including time asleep), from the kernel's boot time. This is not your login time or how long MacMonitor has been open. Shown in your Mac's time zone.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Uptime unavailable: macOS didn't report its boot time.").foregroundStyle(.secondary)
            }
        }
    }
}
