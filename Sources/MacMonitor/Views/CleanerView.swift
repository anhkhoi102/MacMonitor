import SwiftUI

/// Storage Cleaner dashboard.
///
/// Approval workflow: 1 scan → 2 report → 3 review lists → 4 you tick items →
/// 5 confirmation screen → 6 you confirm → 7 items move to the Trash →
/// 8 results. Nothing is scanned until you press "Scan", and nothing is ever
/// selected or cleaned automatically.
struct CleanerView: View {
    @Environment(DashboardViewModel.self) private var vm
    @AppStorage("cleanerIncludeLargeFiles") private var includeLargeFiles = false
    var body: some View {
        @Bindable var vm = vm
        Group {
            if let category = vm.cleanerOpenCategory, let report = vm.scanReport?.report(for: category) {
                CleanerCategoryView(report: report) { vm.cleanerOpenCategory = nil }
            } else {
                dashboard
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { SelectionBar() }
        .sheet(item: $vm.cleanupPlan) { plan in ConfirmCleanupSheet(plan: plan) }
    }

    private var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Storage Cleaner", subtitle: "Find caches, logs and other files you may not need")

                Label("You stay in control: scanning only measures files, nothing is ever selected for you, and every cleanup needs your confirmation. Cleaned items go to the Trash, so you can put them back.",
                      systemImage: "lock.shield")
                    .font(.callout)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

                scanControls

                if let report = vm.scanReport {
                    HStack(spacing: 12) {
                        StatTile(title: "Potentially Recoverable", value: Fmt.storage(report.recoverableSize),
                                 systemImage: "arrow.3.trianglepath", tint: .green)
                        StatTile(title: "Total Analyzed", value: Fmt.storage(report.analyzedSize),
                                 systemImage: "magnifyingglass", tint: .blue)
                        StatTile(title: "Files Detected", value: report.fileCount.formatted(),
                                 systemImage: "doc.on.doc", tint: .purple)
                    }
                    breakdown(report)
                } else if !vm.isScanning {
                    ContentUnavailableView("No Scan Yet", systemImage: "magnifyingglass",
                                           description: Text("Press Scan to analyze caches, logs, temporary files and more."))
                        .frame(maxWidth: .infinity, minHeight: 220)
                }
            }
            .padding(24)
        }
    }

    // MARK: Scan button and progress

    private var scanControls: some View {
        Card(title: "Scan", systemImage: "magnifyingglass", tint: .green) {
            switch vm.scanState {
            case .scanning(let progress):
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Scanning \(progress.category.title)…").font(.callout.weight(.medium))
                        Spacer()
                        Text("\(progress.filesSeen.formatted()) files").font(.callout).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double(progress.step), total: Double(progress.totalSteps)).tint(.green)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .cancelled:
                Label("Scan canceled.", systemImage: "xmark.circle").foregroundStyle(.secondary)
            case .idle:
                if let report = vm.scanReport {
                    Text("Last scan \(report.date.formatted(date: .omitted, time: .shortened)) · took \(report.duration.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow, maximumUnitCount: 1)))")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            HStack {
                Toggle("Include large files (over 500 MB) in Downloads, Desktop, Documents and Movies", isOn: $includeLargeFiles)
                    .toggleStyle(.checkbox)
                    .help("macOS will ask once for permission to read each of these folders.")
                    .disabled(vm.isScanning)
                Spacer()
                if vm.isScanning {
                    Button("Cancel", role: .cancel) { vm.cancelScan() }
                } else {
                    Button(vm.scanReport == nil ? "Scan" : "Rescan") { vm.startScan(includeLargeFiles: includeLargeFiles) }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                }
            }
        }
    }

    // MARK: Breakdown table

    private func breakdown(_ report: ScanReport) -> some View {
        let largest = Double(report.categories.map(\.size).max() ?? 1)
        return Card(title: "Breakdown by Category", systemImage: "list.bullet.rectangle", tint: .green) {
            VStack(spacing: 0) {
                ForEach(report.categories) { row in
                    HStack(spacing: 8) {
                        // Whole-category checkbox: ticks every eligible item;
                        // shows "–" when only some are ticked.
                        TriStateCheckbox(state: vm.selectionState(of: row), title: row.category.title) {
                            vm.toggleCategory(row)
                        }
                        .disabled(row.items.isEmpty || !row.category.isSelectable || vm.isCleaning)
                        .opacity(row.category.isSelectable ? 1 : 0)
                        .help(row.category.isSelectable ? "Select or deselect everything in \(row.category.title)"
                                                        : "Large files are review-only")
                        Button { vm.cleanerOpenCategory = row.category } label: {
                            categoryRow(row, largest: max(largest, 1))
                        }
                        .buttonStyle(.plain)
                        .disabled(row.items.isEmpty)
                        // Fixed-width slot so every row's bar and size line up.
                        ZStack(alignment: .trailing) {
                            Color.clear.frame(width: 110, height: 1)   // always takes up the slot
                            if row.status == .needsPermission || row.notes.contains(where: { $0.contains("Full Disk Access") }) {
                                Button("Grant Access…") { openFullDiskAccessSettings() }
                                    .controlSize(.small)
                                    .help("Opens System Settings › Privacy & Security › Full Disk Access. Optional – you decide.")
                            }
                        }
                        .frame(width: 110, alignment: .trailing)
                    }
                    if row.category != report.categories.last?.category { Divider() }
                }
            }
            Text("Check a category to select everything in it, or click it to review and check individual items. Large files are review-only: they can't be selected and aren't counted as recoverable.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func categoryRow(_ row: CategoryReport, largest: Double) -> some View {
        HStack(spacing: 12) {
            Image(systemName: row.category.systemImage)
                .foregroundStyle(row.category.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.category.title).font(.callout.weight(.medium))
                Text(statusText(row)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(minWidth: 260, maxWidth: 420, alignment: .leading)
            UsageBar(value: Double(row.size) / largest * 100, tint: row.category.tint, height: 6)
                .frame(maxWidth: .infinity)
            Text(row.items.isEmpty ? "—" : Fmt.storage(row.size))
                .font(.callout.weight(.medium)).monospacedDigit()
                .frame(width: 90, alignment: .trailing)
            Text(row.items.isEmpty ? "" : "\(row.items.count)")
                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            Image(systemName: "chevron.right")
                .foregroundStyle(row.items.isEmpty ? .clear : .secondary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func statusText(_ row: CategoryReport) -> String {
        let main: String = switch row.status {
        case .scanned: row.items.isEmpty ? "Nothing found" : selectedText(row) + "\(row.fileCount.formatted()) files"
        case .notPresent: "Not present on this Mac"
        case .needsPermission: "macOS protects this folder – needs Full Disk Access"
        case .skipped: "Not scanned – turn on “Include large files” above"
        }
        return ([main] + row.notes).joined(separator: " · ")
    }

    private func selectedText(_ row: CategoryReport) -> String {
        let count = row.items.filter { vm.isSelected($0) }.count
        return count == 0 ? "" : "\(count) selected (\(Fmt.storage(vm.selectedSize(in: row)))) · "
    }

    /// Opens System Settings › Privacy & Security › Full Disk Access.
    /// The user decides; MacMonitor never asks for admin rights.
    private func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
