import SwiftUI
import Charts

struct MemoryView: View {
    @Environment(DashboardViewModel.self) private var vm
    /// Show every app instead of the top 10.
    @ViewState private var showAllApps = false

    var body: some View {
        let m = vm.memory
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Memory", subtitle: "Physical RAM usage and pressure", showsMockBadge: vm.isMock(.memory))

                HStack(spacing: 12) {
                    StatTile(title: "Total", value: Fmt.memoryGB(m.total, decimals: 0), systemImage: "memorychip", tint: .purple)
                    StatTile(title: "Used", value: Fmt.memoryGB(m.used), systemImage: "square.stack.3d.up.fill", tint: .purple)
                    StatTile(title: "Available", value: Fmt.memoryGB(m.available), systemImage: "square.stack.3d.up", tint: .gray)
                    StatTile(title: "Utilization", value: Fmt.percent(m.utilization), systemImage: "percent", tint: .purple)
                }

                HStack(alignment: .top, spacing: 16) {
                    Card(title: "Memory Pressure", systemImage: "gauge.with.needle", tint: m.pressure.color) {
                        HStack(spacing: 20) {
                            RingGauge(value: m.pressurePercent, tint: m.pressure.color, caption: m.pressure.title)
                            VStack(alignment: .leading, spacing: 8) {
                                Text(pressureExplanation(m.pressure))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                StatRow(label: "Swap used",
                                        value: m.swapTotal > 0 ? "\(Fmt.memoryGB(m.swapUsed)) of \(Fmt.memoryGB(m.swapTotal))" : "None",
                                        tint: .indigo)
                            }
                        }
                    }

                    Card(title: "Utilization History", systemImage: "chart.xyaxis.line", tint: .purple) {
                        HistoryChart(history: vm.memoryHistory, tint: .purple, showsAxes: true, height: 110)
                        Text("Used = App Memory + Wired + Compressed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                memoryByTypeCard(m)
                memoryByAppCard
            }
            .padding(24)
        }
        // Scan processes only while this page is visible.
        .task { await vm.monitorAppMemory() }
    }

    // MARK: Memory by type

    private func memoryByTypeCard(_ m: MemoryStats) -> some View {
        Card(title: "Memory by Type", systemImage: "chart.pie.fill", tint: .purple) {
            HStack(alignment: .center, spacing: 28) {
                Chart(m.segments) { segment in
                    SectorMark(angle: .value("Bytes", Double(segment.bytes)),
                               innerRadius: .ratio(0.62), angularInset: 1.2)
                        .foregroundStyle(segment.color)
                        .cornerRadius(3)
                }
                .frame(width: 160, height: 160)
                .overlay {
                    VStack(spacing: 0) {
                        Text(Fmt.memoryGB(m.total, decimals: 0))
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                        Text("total").font(.caption).foregroundStyle(.secondary)
                    }
                }

                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 9) {
                    ForEach(m.segments) { segment in
                        GridRow {
                            Circle().fill(segment.color).frame(width: 9, height: 9)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(segment.title).font(.callout.weight(.medium))
                                Text(segment.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(Fmt.memoryGB(segment.bytes, decimals: 2))
                                .font(.callout.weight(.medium)).monospacedDigit()
                                .gridColumnAlignment(.trailing)
                            Text(share(segment.bytes, of: m.total))
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                .gridColumnAlignment(.trailing)
                        }
                    }
                }
            }
        }
    }

    // MARK: Memory by app

    private var memoryByAppCard: some View {
        let report = vm.appMemory
        let largest = Double(report.apps.first?.footprint ?? 1)
        let visible = showAllApps ? report.apps : Array(report.apps.prefix(10))

        return Card(title: "Memory by App", systemImage: "square.grid.2x2.fill", tint: .purple) {
            if report.apps.isEmpty {
                ProgressView("Reading running apps…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                VStack(spacing: 8) {
                    ForEach(visible) { app in
                        HStack(spacing: 10) {
                            AppIconView(bundlePath: app.bundlePath)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(app.name).lineLimit(1)
                                    if app.processCount > 1 {
                                        Text("\(app.processCount) processes")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(Fmt.appMemory(app.footprint))
                                        .fontWeight(.medium).monospacedDigit()
                                }
                                .font(.callout)
                                UsageBar(value: Double(app.footprint) / largest * 100, tint: .purple, height: 5)
                            }
                        }
                        .help(app.bundlePath ?? app.id)
                    }
                }

                HStack {
                    Text("\(report.readableProcessCount) processes · \(report.restrictedProcessCount) system processes not shown (need admin rights) · updates every 5 s")
                    Spacer()
                    if report.apps.count > 10 {
                        Button(showAllApps ? "Show top 10" : "Show all \(report.apps.count)") {
                            showAllApps.toggle()
                        }
                        .buttonStyle(.link)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Text("Same figure as Activity Monitor's Memory column (physical footprint). It includes compressed and swapped memory, so the list can add up to more than “Used”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Helpers

    private func share(_ bytes: UInt64, of total: UInt64) -> String {
        total == 0 ? "–" : String(format: "%.0f%%", Double(bytes) / Double(total) * 100)
    }

    private func pressureExplanation(_ level: MemoryPressure) -> String {
        switch level {
        case .normal:
            "Normal: macOS has memory to spare. High utilization is fine – unused RAM is wasted RAM."
        case .warning:
            "Warning: macOS is compressing memory and using swap to keep up. Quitting unused apps will help."
        case .critical:
            "Critical: the Mac is short of memory and may feel slow. Quit apps you are not using."
        }
    }
}

/// An app's icon, or a generic symbol for background processes.
struct AppIconView: View {
    let bundlePath: String?
    /// Filled in *after* the view appears (see `.task`), never while SwiftUI
    /// or a table is building rows: loading an icon from disk during that
    /// step triggers macOS's "reentrant operation in NSTableView" warning.
    @ViewState private var icon: NSImage?

    var body: some View {
        Group {
            if let icon = icon ?? bundlePath.flatMap(AppIconCache.cachedIcon(for:)) {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: "gearshape.2")
                    .resizable().scaledToFit().padding(5)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 26, height: 26)
        .task(id: bundlePath) {
            icon = bundlePath.flatMap(AppIconCache.icon(for:))
        }
    }
}

/// Loading an icon from disk is relatively expensive, so each one is loaded
/// once and reused. Only paths actually shown on screen end up here.
@MainActor
enum AppIconCache {
    private static var icons: [String: NSImage] = [:]

    /// Already-loaded icon, or nil (never touches the disk).
    static func cachedIcon(for bundlePath: String) -> NSImage? { icons[bundlePath] }

    static func icon(for bundlePath: String) -> NSImage? {
        if let cached = icons[bundlePath] { return cached }
        guard FileManager.default.fileExists(atPath: bundlePath) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: bundlePath)
        icon.size = NSSize(width: 26, height: 26)
        icons[bundlePath] = icon
        return icon
    }
}
