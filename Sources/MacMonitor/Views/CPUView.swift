import SwiftUI

struct CPUView: View {
    @Environment(DashboardViewModel.self) private var vm

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "CPU", subtitle: "\(vm.processorName) · \(vm.cpu.cores.count) cores",
                           showsMockBadge: vm.isMock(.cpu))

                HStack(spacing: 12) {
                    StatTile(title: "Total", value: Fmt.percent(vm.cpu.total), systemImage: "gauge.with.dots.needle.33percent", tint: .blue)
                    StatTile(title: "User", value: Fmt.percent(vm.cpu.user), systemImage: "person", tint: .blue)
                    StatTile(title: "System", value: Fmt.percent(vm.cpu.system), systemImage: "gearshape.2", tint: .red)
                    StatTile(title: "Idle", value: Fmt.percent(vm.cpu.idle), systemImage: "moon.zzz", tint: .gray)
                }

                Card(title: "History", systemImage: "chart.xyaxis.line", tint: .blue) {
                    SparklineChart(
                        series: [
                            ChartSeries(points: vm.cpuHistory.points, color: .blue, filled: true),
                            ChartSeries(points: vm.cpuUserHistory.points, color: .teal, dashed: true),
                        ],
                        capacity: vm.cpuHistory.capacity, maxValue: 100, showsGrid: true,
                        gridLabel: { String(format: "%.0f%%", $0) }, height: 220)

                    HStack(spacing: 16) {
                        Label("Total", systemImage: "line.diagonal").foregroundStyle(.blue)
                        Label("User", systemImage: "line.diagonal").foregroundStyle(.teal)
                        Spacer()
                        Text("Last \(vm.historySeconds / 60) min")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Card(title: "Thermal State", systemImage: "thermometer.medium", tint: vm.thermalState.color) {
                    HStack(alignment: .top, spacing: 32) {
                        // Only shown when macOS actually provides a temperature.
                        if case .celsius(let value) = vm.cpuTemperature {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("CPU temperature").font(.caption).foregroundStyle(.secondary)
                                Text(String(format: "%.0f°C", value)).font(.title3.weight(.semibold))
                            }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Label(vm.thermalState.title, systemImage: "circle.fill")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(vm.thermalState.color, .primary)
                            Text(vm.thermalState.explanation).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    Text("Reported by macOS: how hard it is working to keep the Mac cool (Nominal, Fair, Serious or Critical).")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(alignment: .top, spacing: 16) {
                    Card(title: "Cores", systemImage: "square.grid.3x3.fill", tint: .blue) {
                        coreBars
                        HStack(spacing: 14) {
                            if vm.cpu.cores.contains(where: { $0.kind == .efficiency }) {
                                Label("Efficiency", systemImage: "leaf.fill").foregroundStyle(.teal)
                                Label("Performance", systemImage: "bolt.fill").foregroundStyle(.blue)
                            }
                            Spacer()
                        }
                        .font(.caption)
                    }

                    Card(title: "Breakdown", systemImage: "chart.bar.fill", tint: .blue) {
                        breakdownBar
                        VStack(spacing: 6) {
                            StatRow(label: "User", value: Fmt.percent(vm.cpu.user), tint: .blue)
                            StatRow(label: "System", value: Fmt.percent(vm.cpu.system), tint: .red)
                            StatRow(label: "Idle", value: Fmt.percent(vm.cpu.idle), tint: .gray.opacity(0.4))
                            Divider()
                            StatRow(label: "MacMonitor itself", value: String(format: "%.1f%%", vm.ownCPUUsage), tint: .green)
                        }
                        Text("User = apps. System = the macOS kernel. “MacMonitor itself” is measured like Activity Monitor’s % CPU column (100% = one full core).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(24)
        }
    }

    /// One vertical bar per core.
    private var coreBars: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(vm.cpu.cores) { core in
                let tint: Color = core.kind == .efficiency ? .teal : .blue
                VStack(spacing: 6) {
                    Text(Fmt.percent(core.usage))
                        .font(.caption2.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    GeometryReader { geo in
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 5).fill(tint.opacity(0.14))
                            RoundedRectangle(cornerRadius: 5).fill(tint)
                                .frame(height: geo.size.height * min(1, core.usage / 100))
                        }
                    }
                    .frame(height: 110)
                    Text("\(core.kind.shortLabel)\(index(of: core))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 44)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// 1-based number within its kind, e.g. the second efficiency core is "E2".
    private func index(of core: CoreUsage) -> Int {
        vm.cpu.cores.filter { $0.kind == core.kind && $0.id <= core.id }.count
    }

    /// Stacked bar showing user / system / idle shares.
    private var breakdownBar: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                Rectangle().fill(.blue).frame(width: geo.size.width * vm.cpu.user / 100)
                Rectangle().fill(.red).frame(width: geo.size.width * vm.cpu.system / 100)
                Rectangle().fill(.gray.opacity(0.25))
            }
            .clipShape(Capsule())
        }
        .frame(height: 14)
    }
}
