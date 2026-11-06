import SwiftUI
import Charts

struct StorageView: View {
    @Environment(DashboardViewModel.self) private var vm

    var body: some View {
        let d = vm.disk
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Storage", subtitle: "Capacity of the startup volume and what uses it", showsMockBadge: vm.isMock(.storage))

                HStack(spacing: 12) {
                    StatTile(title: "Capacity", value: Fmt.storage(d.total), systemImage: "internaldrive", tint: .orange)
                    StatTile(title: "Used", value: Fmt.storage(d.used), systemImage: "externaldrive.fill", tint: .orange)
                    StatTile(title: "Available", value: Fmt.storage(d.available), systemImage: "externaldrive", tint: .gray)
                    StatTile(title: "Utilization", value: Fmt.percent(d.utilization), systemImage: "percent", tint: .orange)
                }

                Card(title: d.volumeName, systemImage: "internaldrive.fill", tint: .orange) {
                    HStack(spacing: 32) {
                        // Donut chart (SectorMark needs macOS 14+).
                        Chart {
                            SectorMark(angle: .value("Bytes", Double(d.used)), innerRadius: .ratio(0.68), angularInset: 1.5)
                                .foregroundStyle(.orange)
                                .cornerRadius(4)
                            SectorMark(angle: .value("Bytes", Double(d.available)), innerRadius: .ratio(0.68), angularInset: 1.5)
                                .foregroundStyle(.gray.opacity(0.25))
                                .cornerRadius(4)
                        }
                        .frame(width: 180, height: 180)
                        .overlay {
                            VStack(spacing: 2) {
                                Text(Fmt.percent(d.utilization))
                                    .font(.system(size: 30, weight: .bold, design: .rounded))
                                Text("used").font(.caption).foregroundStyle(.secondary)
                            }
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            StatRow(label: "Used", value: Fmt.storage(d.used), tint: .orange)
                            StatRow(label: "Available", value: Fmt.storage(d.available), tint: .gray.opacity(0.4))
                            StatRow(label: "   Free now", value: Fmt.storage(d.free))
                            StatRow(label: "   Purgeable", value: Fmt.storage(d.purgeable))
                            Divider()
                            StatRow(label: "Total", value: Fmt.storage(d.total))
                            UsageBar(value: d.utilization, tint: .orange, animated: true)
                                .padding(.top, 4)
                        }
                        .frame(maxWidth: 360)
                    }
                    Text("“Available” matches Finder: free space plus purgeable space (caches and snapshots macOS removes automatically when it needs room). Sizes use decimal units (1 GB = 1,000,000,000 bytes), like Finder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                DiskAnalyzerCard()
            }
            .padding(24)
        }
    }
}
