import SwiftUI

/// Bar shown at the bottom of the Cleaner while anything is selected.
struct SelectionBar: View {
    @Environment(DashboardViewModel.self) private var vm

    var body: some View {
        let items = vm.selectedItems
        if !items.isEmpty {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("\(items.count) item\(items.count == 1 ? "" : "s") selected · \(Fmt.storage(items.reduce(0) { $0 + $1.size }))")
                    .font(.callout.weight(.medium))
                Spacer()
                Button("Clear Selection") { vm.clearSelection() }
                Button("Review Cleanup…") { vm.reviewCleanup() }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
            .disabled(vm.isCleaning)
        }
    }
}

/// Approval steps 5–8 in one sheet:
///  5. shows exactly what will be cleaned,
///  6. waits for an explicit click on "Confirm Cleanup",
///  7. shows progress (with Stop) while items are moved to the Trash,
///  8. shows the results.
struct ConfirmCleanupSheet: View {
    @Environment(DashboardViewModel.self) private var vm
    let plan: CleanupPlan
    /// Separate acknowledgement for items already in the Trash.
    @ViewState private var acknowledgedTrash = false

    private var canConfirm: Bool { !plan.requiresTrashAcknowledgement || acknowledgedTrash }

    var body: some View {
        Group {
            if let outcome = vm.cleanupOutcome, outcome.plan.id == plan.id {
                CleanupResultView(outcome: outcome)
            } else if let progress = vm.cleanupProgress {
                progressView(progress)
            } else {
                confirmation
            }
        }
        .padding(24)
        .frame(width: 620)
        .interactiveDismissDisabled(vm.isCleaning)
    }

    // MARK: Step 5 + 6

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Confirm Cleanup", systemImage: "checkmark.shield")
                .font(.title2.weight(.bold))

            HStack(alignment: .firstTextBaseline, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("You are about to remove").foregroundStyle(.secondary)
                    Text("\(plan.items.count) item\(plan.items.count == 1 ? "" : "s") · \(Fmt.storage(plan.totalSize))")
                        .font(.title3.weight(.semibold))
                    Text("\(plan.fileCount.formatted()) files in total").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if plan.highRiskCount > 0 {
                    Label("\(plan.highRiskCount) high-risk item\(plan.highRiskCount == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).font(.callout.weight(.medium))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Selected categories").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(plan.categories, id: \.category) { entry in
                    HStack {
                        Image(systemName: entry.category.systemImage).foregroundStyle(entry.category.tint).frame(width: 18)
                        Text(entry.category.title)
                        Spacer()
                        Text("\(entry.count) · \(Fmt.storage(entry.size))").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Exact files and folders").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                List(plan.items) { item in
                    HStack(spacing: 8) {
                        Image(systemName: item.isDirectory ? "folder" : "doc").foregroundStyle(.secondary)
                        Text(abbreviatedPath(item.url)).lineLimit(1).truncationMode(.middle).help(item.path)
                        Spacer()
                        Text(item.risk.title).font(.caption2.weight(.semibold)).foregroundStyle(item.risk.color)
                        Text(Fmt.storage(item.size)).monospacedDigit().frame(width: 76, alignment: .trailing)
                    }
                    .font(.callout)
                }
                .listStyle(.bordered)
                .frame(minHeight: 140, maxHeight: 220)
            }

            VStack(alignment: .leading, spacing: 6) {
                Label("Items are moved to the Trash, not deleted. You can put them back from the Trash until you empty it.",
                      systemImage: "trash")
                Label("This operation cannot be automatically reversed by MacMonitor.", systemImage: "arrow.uturn.backward.circle")
                Label("Each item is checked again first. Anything changed since the scan, or open in a running app, is skipped.",
                      systemImage: "checkmark.seal")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            if plan.requiresTrashAcknowledgement {
                Toggle(isOn: $acknowledgedTrash) {
                    Text("I understand that the \(plan.trashItems.count) item(s) already in the Trash will be **permanently deleted** and cannot be recovered.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)
                .padding(10)
                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { vm.cleanupPlan = nil }
                    .keyboardShortcut(.cancelAction)   // Esc cancels. No Return shortcut: confirming takes a deliberate click.
                Button("Confirm Cleanup") {
                    vm.confirmCleanup(plan, trashAcknowledged: acknowledgedTrash)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!canConfirm)
            }
        }
    }

    // MARK: Step 7

    private func progressView(_ progress: CleanupProgress) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Cleaning Up…", systemImage: "trash").font(.title2.weight(.bold))
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))).tint(.green)
            HStack {
                Text(progress.currentName.isEmpty ? "Finishing…" : "Checking and moving \(progress.currentName)")
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("\(progress.done) of \(progress.total)").monospacedDigit()
            }
            .font(.callout).foregroundStyle(.secondary)
            HStack {
                Text("Stop finishes the current item and leaves the rest untouched.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Stop") { vm.stopCleanup() }
            }
        }
    }
}

/// Step 8: what happened to each approved item.
struct CleanupResultView: View {
    @Environment(DashboardViewModel.self) private var vm
    let outcome: CleanupOutcome

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(outcome.wasStopped ? "Cleanup Stopped" : "Cleanup Complete",
                  systemImage: outcome.wasStopped ? "stop.circle" : "checkmark.circle.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(outcome.wasStopped ? .orange : .green, .primary)

            HStack(spacing: 12) {
                StatTile(title: "Space freed", value: Fmt.storage(outcome.freedSize),
                         systemImage: "sparkles", tint: .green)
                StatTile(title: "Moved to Trash", value: "\(outcome.movedCount)",
                         systemImage: "trash", tint: .blue)
                StatTile(title: "Not cleaned", value: "\(outcome.notCleaned.count)",
                         systemImage: "forward.end", tint: outcome.notCleaned.isEmpty ? .gray : .orange)
            }
            if outcome.deletedCount > 0 {
                Label("\(outcome.deletedCount) item(s) from the Trash were deleted permanently, as you confirmed.",
                      systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
            }

            if !outcome.notCleaned.isEmpty {
                Text("Not cleaned").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                List(outcome.notCleaned) { result in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(abbreviatedPath(result.item.url)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(result.kind.title).font(.caption.weight(.semibold))
                                .foregroundStyle(result.kind == .notAttempted ? .secondary : Color.orange)
                        }
                        if let detail = result.kind.detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.bordered)
                .frame(minHeight: 90, maxHeight: 200)
            }

            if outcome.movedCount > 0 {
                Text("Changed your mind? Open the Trash in Finder and use File › Put Back.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            HStack {
                if outcome.movedCount > 0 {
                    Button("Open Trash") {
                        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash"))
                    }
                }
                Spacer()
                Button("Done") {
                    vm.cleanupOutcome = nil
                    vm.cleanupPlan = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}
