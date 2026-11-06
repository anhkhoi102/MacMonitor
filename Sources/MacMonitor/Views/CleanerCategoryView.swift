import SwiftUI

/// Review list for one cleanup category: every file or folder found, with
/// size, date, risk and location, plus a checkbox to select it for cleanup.
/// Nothing is pre-selected – you tick what you want (approval step 4).
struct CleanerCategoryView: View {
    @Environment(DashboardViewModel.self) private var vm
    let report: CategoryReport
    let onBack: () -> Void

    @ViewState private var sortOrder = [KeyPathComparator(\CleanupItem.sizeForSorting, order: .reverse)]
    @ViewState private var selection: CleanupItem.ID?
    @ViewState private var infoItem: CleanupItem?

    private var sortedItems: [CleanupItem] { report.items.sorted(using: sortOrder) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button { onBack() } label: { Label("All Categories", systemImage: "chevron.left") }
                    .buttonStyle(.link)
                Spacer()
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(report.category.title, systemImage: report.category.systemImage)
                        .font(.title.weight(.bold))
                        .foregroundStyle(report.category.tint, .primary)
                    Text(report.category.explanation).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Fmt.storage(report.size)).font(.title2.weight(.semibold)).monospacedDigit()
                    Text("\(report.items.count) items · \(report.fileCount.formatted()) files")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if !report.category.isSelectable {
                Label("Review only: these are your own large files (videos, downloads, documents). MacMonitor never removes them. Use Show in Finder to decide yourself.",
                      systemImage: "hand.raised")
                    .font(.callout)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            } else { HStack(spacing: 10) {
                let selectedHere = report.items.filter { vm.isSelected($0) }
                Text(selectedHere.isEmpty ? "Nothing selected in this category"
                     : "\(selectedHere.count) of \(report.items.count) selected · \(Fmt.storage(selectedHere.reduce(0) { $0 + $1.size }))")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Select Low Risk") { vm.select(report.items.filter { $0.risk == .low }) }
                    .disabled(!report.items.contains { $0.risk == .low })
                    .help("Selects only items marked Low risk.")
                Button("Select All") { vm.select(report.items) }
                Button("Deselect All") { vm.deselect(report.items) }
                    .disabled(selectedHere.isEmpty)
            }
            .controlSize(.small) }

            Table(sortedItems, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("") { item in
                    if item.category.isSelectable {
                        Toggle("Select \(item.name)", isOn: Binding(
                            get: { vm.isSelected(item) },
                            set: { vm.setSelected(item, $0) }))
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                    }
                }
                .width(22)
                TableColumn("Name", value: \.name) { item in
                    Label(item.name, systemImage: item.isDirectory ? "folder" : "doc")
                        .lineLimit(1)
                        .help(item.path)
                }
                .width(min: 160, ideal: 240)
                TableColumn("Size", value: \.sizeForSorting) { item in
                    Text(Fmt.storage(item.size)).monospacedDigit()
                }
                .width(min: 70, ideal: 90)
                TableColumn("Modified", value: \.modifiedForSorting) { item in
                    Text(item.modified.formatted(date: .abbreviated, time: .omitted))
                }
                .width(min: 90, ideal: 110)
                TableColumn("Risk") { item in
                    Text(item.risk.title)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .foregroundStyle(item.risk.color)
                        .background(item.risk.color.opacity(0.14), in: Capsule())
                        .help(item.riskReason)
                }
                .width(60)
                TableColumn("") { item in
                    HStack(spacing: 6) {
                        Button { infoItem = item } label: { Image(systemName: "info.circle") }
                            .help("Show details")
                        Button { reveal(item) } label: { Image(systemName: "magnifyingglass") }
                            .help("Show in Finder")
                    }
                    .buttonStyle(.borderless)
                }
                .width(52)
                TableColumn("Location") { item in
                    Text(abbreviatedPath(item.url.deletingLastPathComponent()))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(item.path)
                }
                .width(min: 160, ideal: 280)
            }
            .contextMenu(forSelectionType: CleanupItem.ID.self) { ids in
                if let id = ids.first, let item = report.items.first(where: { $0.id == id }) {
                    Button("Show in Finder") { reveal(item) }
                    Button("Show Details") { infoItem = item }
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.path, forType: .string)
                    }
                }
            } primaryAction: { ids in
                if let id = ids.first, let item = report.items.first(where: { $0.id == id }) { infoItem = item }
            }

            if !report.notes.isEmpty {
                Text(report.notes.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
            Text("Check the items to clean, then click Review Cleanup at the bottom. Double-click a row for details, or use Show in Finder.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .sheet(item: $infoItem) { item in
            ItemInfoSheet(item: item) { infoItem = nil }
        }
    }

    private func reveal(_ item: CleanupItem) {
        // Opens a Finder window with the item selected. Changes nothing.
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }
}

/// "~/Library/Caches" instead of "/Users/name/Library/Caches".
func abbreviatedPath(_ url: URL) -> String {
    (url.path as NSString).abbreviatingWithTildeInPath
}

/// Detailed information about one item ("Preview file information").
struct ItemInfoSheet: View {
    let item: CleanupItem
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                    .resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.title3.weight(.semibold)).lineLimit(2)
                    Text(item.category.title).foregroundStyle(.secondary)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow { Text("Full path").foregroundStyle(.secondary); Text(item.path).textSelection(.enabled) }
                GridRow { Text("Size").foregroundStyle(.secondary); Text("\(Fmt.storage(item.size)) on disk") }
                GridRow { Text("Contains").foregroundStyle(.secondary); Text(item.isDirectory ? "\(item.fileCount.formatted()) files" : "Single file") }
                GridRow { Text("Last modified").foregroundStyle(.secondary); Text(item.modified.formatted(date: .long, time: .shortened)) }
                GridRow {
                    Text("Risk").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.risk.title).foregroundStyle(item.risk.color).fontWeight(.semibold)
                        Text(item.riskReason).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
                GridRow { Text("Found in").foregroundStyle(.secondary); Text(abbreviatedPath(item.root)) }
            }
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                Spacer()
                Button("Done") { onClose() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}
