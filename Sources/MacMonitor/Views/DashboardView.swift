import SwiftUI

/// Overview page: one card per subsystem, laid out in an adaptive grid that
/// reflows from 2 columns to 1 as the window gets narrower.
struct DashboardView: View {
    @Environment(DashboardViewModel.self) private var vm
    @Binding var selection: SidebarItem?
    @AppStorage(SettingsKey.speedUnit) private var speedUnitRaw = NetworkSpeedUnit.megabytesPerSecond.rawValue

    private var speedUnit: NetworkSpeedUnit { NetworkSpeedUnit(rawValue: speedUnitRaw) ?? .megabytesPerSecond }
    private let columns = [GridItem(.adaptive(minimum: 340), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Overview", subtitle: "Your Mac at a glance",
                           showsMockBadge: !vm.mockMetrics.isEmpty, mockBadgeText: "Partly simulated")

                if let battery = vm.battery {
                    batteryStrip(battery)
                }

                LazyVGrid(columns: columns, spacing: 16) {
                    cpuCard
                    memoryCard
                    storageCard
                    networkCard
                }
                TopProcessesCard()
            }
            .padding(24)
        }
    }

    // MARK: Cards

    private var cpuCard: some View {
        Card(title: "CPU", systemImage: "cpu", tint: .blue) {
            HStack(spacing: 20) {
                RingGauge(value: vm.cpu.total, tint: .blue, caption: "in use")
                VStack(spacing: 8) {
                    StatRow(label: "User", value: Fmt.percent(vm.cpu.user), tint: .blue)
                    StatRow(label: "System", value: Fmt.percent(vm.cpu.system), tint: .red)
                    StatRow(label: "Idle", value: Fmt.percent(vm.cpu.idle), tint: .gray)
                    temperatureRow
                }
            }
            HistoryChart(history: vm.cpuHistory, tint: .blue)
            cardFooter(vm.processorName, "Last \(vm.historySeconds / 60) min")
        }
        .onTapGesture { selection = .cpu }
    }

    private var memoryCard: some View {
        Card(title: "Memory", systemImage: "memorychip", tint: .purple, isMock: vm.isMock(.memory)) {
            HStack(spacing: 20) {
                RingGauge(value: vm.memory.utilization, tint: .purple, caption: "used")
                VStack(spacing: 8) {
                    StatRow(label: "Used", value: Fmt.memoryGB(vm.memory.used), tint: .purple)
                    StatRow(label: "Available", value: Fmt.memoryGB(vm.memory.available), tint: .gray)
                    StatRow(label: "Pressure", value: vm.memory.pressure.title, tint: vm.memory.pressure.color)
                    StatRow(label: "Swap", value: Fmt.memoryGB(vm.memory.swapUsed), tint: .indigo)
                }
            }
            HistoryChart(history: vm.memoryHistory, tint: .purple)
            cardFooter("Total \(Fmt.memoryGB(vm.memory.total, decimals: 0))",
                       "Compressed \(Fmt.memoryGB(vm.memory.compressed))")
        }
        .onTapGesture { selection = .memory }
    }

    private var storageCard: some View {
        Card(title: "Storage", systemImage: "internaldrive", tint: .orange, isMock: vm.isMock(.storage)) {
            HStack(spacing: 20) {
                RingGauge(value: vm.disk.utilization, tint: .orange, caption: "full")
                VStack(spacing: 8) {
                    StatRow(label: "Capacity", value: Fmt.storage(vm.disk.total))
                    StatRow(label: "Used", value: Fmt.storage(vm.disk.used), tint: .orange)
                    StatRow(label: "Available", value: Fmt.storage(vm.disk.available), tint: .gray)
                }
            }
            UsageBar(value: vm.disk.utilization, tint: .orange, animated: true)
                .frame(height: 70)
            cardFooter(vm.disk.volumeName, "\(Fmt.storage(vm.disk.available)) free")
        }
        .onTapGesture { selection = .storage }
    }

    private var networkCard: some View {
        Card(title: "Network", systemImage: "network", tint: .green, isMock: vm.isMock(.network)) {
            HStack(spacing: 16) {
                speedBlock("Download", vm.network.downloadBytesPerSecond, "arrow.down.circle.fill", .green)
                speedBlock("Upload", vm.network.uploadBytesPerSecond, "arrow.up.circle.fill", .cyan)
            }
            .frame(height: 96)
            DualHistoryChart(first: vm.downloadHistory, second: vm.uploadHistory,
                             firstLabel: "Download", secondLabel: "Upload",
                             firstTint: .green, secondTint: .cyan)
            cardFooter(vm.network.isConnected ? "\(vm.network.interfaceType) · \(vm.network.interfaceName)" : "Not connected",
                       "↓ \(Fmt.storage(vm.network.totalDownloaded))  ↑ \(Fmt.storage(vm.network.totalUploaded))")
        }
        .onTapGesture { selection = .network }
    }

    /// One-line battery summary; click it to open the Battery page.
    private func batteryStrip(_ b: BatteryStats) -> some View {
        Button { selection = .battery } label: {
            HStack(spacing: 10) {
                Image(systemName: b.symbolName)
                    .font(.title3)
                    .foregroundStyle(b.isPluggedIn ? .green : (b.percent <= 20 ? .orange : .primary))
                Text("\(b.percent)%").font(.headline).monospacedDigit()
                Text(b.state.title).foregroundStyle(.secondary)
                if b.minutesRemaining != nil {
                    Text("· \(Fmt.duration(minutes: b.minutesRemaining)) \(b.isCharging ? "until full" : "left")")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let health = b.estimatedHealth {
                    Text("Health ≈ \(Int(health.rounded()))% · \(b.cycleCount) cycles")
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .font(.callout)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The real CPU temperature when macOS provides one. Otherwise the
    /// temperature is not shown at all (no "unavailable" placeholder); the row
    /// shows macOS's thermal state instead – a different, real measurement.
    @ViewBuilder
    private var temperatureRow: some View {
        switch vm.cpuTemperature {
        case .celsius(let value):
            StatRow(label: "Temperature", value: String(format: "%.0f°C", value), tint: .orange)
        case .unavailable:
            StatRow(label: "Thermal State", value: vm.thermalState.title, tint: vm.thermalState.color)
                .help("How hard macOS is working to keep the Mac cool: \(vm.thermalState.explanation)")
        }
    }

    /// Every card ends with the same one-line footer, so all cards in a row
    /// have identical heights and line up neatly.
    private func cardFooter(_ leading: String, _ trailing: String) -> some View {
        HStack {
            Text(leading)
            Spacer()
            Text(trailing).monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func speedBlock(_ title: String, _ bytesPerSecond: Double, _ icon: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.caption.weight(.medium)).foregroundStyle(tint)
            Text(Fmt.speed(bytesPerSecond, unit: speedUnit))
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
