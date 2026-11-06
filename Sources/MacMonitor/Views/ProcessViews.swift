import SwiftUI

// MARK: - Formatting

extension ProcessEntry {
    var cpuText: String { cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—" }
    var memoryPercentText: String { String(format: "%.1f%%", memoryPercent) }
}

/// Explains the two percentages wherever processes are listed.
private let processFootnote = "CPU = share of total CPU capacity (all cores busy = 100%). Memory = share of physical RAM. Your own processes only: macOS doesn't let apps read system or other users' processes without admin rights."

// MARK: - Overview card

/// "Top Processes" on the Overview: the five heaviest processes.
struct TopProcessesCard: View {
    @Environment(DashboardViewModel.self) private var vm
    @ViewState private var endRequest: ProcessEntry?
    @ViewState private var detailsPID: pid_t?

    var body: some View {
        @Bindable var vm = vm
        Card(title: "Top Processes", systemImage: "list.bullet.rectangle", tint: .teal) {
            HStack {
                Picker("Sort by", selection: $vm.processSort) {
                    ForEach(ProcessSortKey.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                Spacer()
                Button("Show All Processes") { vm.selectedPage = .processes }
                    .buttonStyle(.link)
            }

            let rows = vm.topProcesses(5)
            if rows.isEmpty {
                ProgressView("Reading processes…").controlSize(.small).frame(maxWidth: .infinity, minHeight: 80)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("Application / Process")
                        Text("CPU").gridColumnAlignment(.trailing)
                        Text("Memory").gridColumnAlignment(.trailing)
                        Text("PID").gridColumnAlignment(.trailing)
                        Text("Status")
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(rows) { process in
                        GridRow {
                            HStack(spacing: 8) {
                                AppIconView(bundlePath: process.bundlePath).scaleEffect(0.8).frame(width: 22, height: 22)
                                Text(process.name).lineLimit(1)
                            }
                            Text(process.cpuText).monospacedDigit()
                            Text(process.memoryPercentText).monospacedDigit()
                            Text(String(process.pid)).monospacedDigit().foregroundStyle(.secondary)
                            Text(process.status.title).foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button("View Details") { detailsPID = process.pid }
                            Divider()
                            Button("End Process…") { endRequest = process }
                        }
                    }
                }
            }
            Text("Right-click a process to view details or end it. " + processFootnote)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { await vm.monitorProcesses() }
        .endProcessFlow(request: $endRequest)
        .sheet(item: Binding(get: { detailsPID.map(PIDBox.init) }, set: { detailsPID = $0?.pid })) { box in
            ProcessDetailSheet(pid: box.pid, onEnd: { endRequest = $0 })
        }
    }
}

private struct PIDBox: Identifiable { let pid: pid_t; var id: pid_t { pid } }

// MARK: - Full list

/// The complete Process Monitor page.
///
/// Uses a scrolling list rather than SwiftUI's `Table`: the rows re-sort and
/// change every 3 seconds, and `Table` (NSTableView) logs "reentrant operation"
/// warnings for that – which Apple says will become a crash. A lazy list
/// also only builds the rows that are on screen.
struct ProcessesView: View {
    @Environment(DashboardViewModel.self) private var vm
    @ViewState private var search = ""
    @ViewState private var selection: pid_t?
    @ViewState private var sortColumn = SortColumn.cpu
    @ViewState private var ascending = false
    @ViewState private var endRequest: ProcessEntry?
    @ViewState private var detailsPID: pid_t?

    enum SortColumn { case name, cpu, memory, pid }

    private var rows: [ProcessEntry] {
        let all = vm.processSnapshot?.entries ?? []
        let filtered = search.isEmpty ? all : all.filter {
            $0.name.localizedCaseInsensitiveContains(search) || String($0.pid) == search
        }
        let sorted: [ProcessEntry] = switch sortColumn {
        case .name: filtered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .cpu: filtered.sorted { ($0.cpuForSorting, $0.memoryBytes) < ($1.cpuForSorting, $1.memoryBytes) }
        case .memory: filtered.sorted { $0.memoryBytes < $1.memoryBytes }
        case .pid: filtered.sorted { $0.pid < $1.pid }
        }
        // `sorted` is always smallest → largest; `ascending` is the direction shown.
        return ascending ? sorted : sorted.reversed()
    }

    private var selected: ProcessEntry? { selection.flatMap { vm.process(withPID: $0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: "Processes", subtitle: "Running apps and processes, refreshed every 3 seconds")

            HStack(spacing: 10) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search by name or PID", text: $search).textFieldStyle(.plain)
                }
                .padding(6)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                .frame(maxWidth: 280)
                Picker("Sort", selection: Binding(
                    get: { sortColumn == .memory ? ProcessSortKey.memory : .cpu },
                    set: { sort(by: $0 == .memory ? .memory : .cpu, ascending: false) })) {
                    ForEach(ProcessSortKey.allCases) { Text("Sort by \($0.title)").tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                Spacer()
                Button("View Details") { detailsPID = selection }.disabled(selected == nil)
                Button("End Process…") { endRequest = selected }.disabled(selected == nil)
            }

            VStack(spacing: 0) {
                header
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { process in
                            row(process)
                        }
                    }
                }
                .frame(minHeight: 200, maxHeight: .infinity)
                .overlay {
                    if vm.processSnapshot == nil { ProgressView("Reading processes…") }
                    else if rows.isEmpty { ContentUnavailableView.search(text: search) }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))

            // Footnote on its own full-width line. (Next to a Spacer it was
            // squeezed to a sliver, wrapped into thousands of points of height,
            // and stretched the whole window layout.)
            VStack(alignment: .leading, spacing: 4) {
                if let snapshot = vm.processSnapshot {
                    Text("\(snapshot.entries.count) shown · \(snapshot.restrictedCount) system processes hidden")
                }
                Text(processFootnote)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await vm.monitorProcesses() }
        .endProcessFlow(request: $endRequest)
        .sheet(item: Binding(get: { detailsPID.map(PIDBox.init) }, set: { detailsPID = $0?.pid })) { box in
            ProcessDetailSheet(pid: box.pid, onEnd: { endRequest = $0 })
        }
    }

    // MARK: Columns

    private let cpuWidth: CGFloat = 70, memWidth: CGFloat = 80, memPctWidth: CGFloat = 80
    private let pidWidth: CGFloat = 64, statusWidth: CGFloat = 76

    private var header: some View {
        HStack(spacing: 12) {
            headerButton("Application / Process", .name).frame(maxWidth: .infinity, alignment: .leading)
            headerButton("CPU", .cpu).frame(width: cpuWidth, alignment: .trailing)
            headerButton("Memory", .memory).frame(width: memWidth, alignment: .trailing)
            Text("Memory %").frame(width: memPctWidth, alignment: .trailing)
            headerButton("PID", .pid).frame(width: pidWidth, alignment: .trailing)
            Text("Status").frame(width: statusWidth, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func headerButton(_ title: String, _ column: SortColumn) -> some View {
        Button {
            // Same column: flip. New column: names/PIDs A→Z, numbers largest first.
            sort(by: column, ascending: sortColumn == column ? !ascending : (column == .name || column == .pid))
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if sortColumn == column {
                    Image(systemName: ascending ? "chevron.up" : "chevron.down").font(.caption2)
                }
            }
        }
        .buttonStyle(.plain)
        .help("Sort by \(title)")
    }

    private func sort(by column: SortColumn, ascending: Bool) {
        sortColumn = column
        self.ascending = ascending
        if column == .cpu { vm.processSort = .cpu }
        if column == .memory { vm.processSort = .memory }
    }

    private func row(_ process: ProcessEntry) -> some View {
        let isSelected = selection == process.pid
        return HStack(spacing: 12) {
            HStack(spacing: 8) {
                AppIconView(bundlePath: process.bundlePath).scaleEffect(0.75).frame(width: 20, height: 20)
                Text(process.name).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(process.cpuText).frame(width: cpuWidth, alignment: .trailing)
            Text(Fmt.appMemory(process.memoryBytes)).frame(width: memWidth, alignment: .trailing)
            Text(process.memoryPercentText).frame(width: memPctWidth, alignment: .trailing)
            Text(String(process.pid)).foregroundStyle(isSelected ? .primary : .secondary).frame(width: pidWidth, alignment: .trailing)
            Text(process.status.title).foregroundStyle(isSelected ? .primary : .secondary).frame(width: statusWidth, alignment: .leading)
        }
        .font(.callout)
        .monospacedDigit()
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(isSelected ? Color.accentColor.opacity(0.22) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { selection = process.pid; detailsPID = process.pid }
        .onTapGesture { selection = process.pid }
        .contextMenu {
            Button("View Details") { selection = process.pid; detailsPID = process.pid }
            Divider()
            Button("End Process…") { endRequest = process }
        }
        .help(process.path)
    }
}

// MARK: - Details

/// "View Details": live information about one process.
struct ProcessDetailSheet: View {
    @Environment(DashboardViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss
    let pid: pid_t
    let onEnd: (ProcessEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let p = vm.process(withPID: pid) {
                HStack(spacing: 12) {
                    AppIconView(bundlePath: p.bundlePath).scaleEffect(1.6).frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name).font(.title3.weight(.semibold))
                        Text("PID \(p.pid) · \(p.status.title)").foregroundStyle(.secondary)
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    GridRow { Text("CPU").foregroundStyle(.secondary)
                        Text(p.cpuPercent.map { String(format: "%.1f%% of total capacity · %.1f%% of one core", $0, p.cpuPercentOfOneCore ?? 0) } ?? "Measuring…") }
                    GridRow { Text("Memory").foregroundStyle(.secondary)
                        Text("\(Fmt.appMemory(p.memoryBytes)) · \(p.memoryPercentText) of RAM") }
                    GridRow { Text("Started").foregroundStyle(.secondary)
                        Text(p.startDate?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown") }
                    GridRow { Text("Program").foregroundStyle(.secondary)
                        Text(p.path.isEmpty ? "Not available" : p.path).textSelection(.enabled).lineLimit(3) }
                }
                Text("Values update every 3 seconds.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    if !p.path.isEmpty {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p.bundlePath ?? p.path)])
                        }
                    }
                    Button("End Process…") { dismiss(); onEnd(p) }
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            } else {
                ContentUnavailableView("Process Ended", systemImage: "xmark.circle",
                                       description: Text("PID \(pid) is no longer running."))
                HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}

// MARK: - End Process flow

/// Confirmation → graceful quit → (only if needed) Force Quit → result.
private struct EndProcessFlow: ViewModifier {
    @Environment(DashboardViewModel.self) private var vm
    @Binding var request: ProcessEntry?
    @ViewState private var alert: EndAlert?

    enum EndAlert: Identifiable {
        case confirm(ProcessEntry)
        case protected(ProcessEntry, String)
        case stillRunning(ProcessEntry)
        case failed(ProcessEntry, String)

        var id: String {
            switch self {
            case .confirm(let p): "c\(p.pid)"
            case .protected(let p, _): "p\(p.pid)"
            case .stillRunning(let p): "s\(p.pid)"
            case .failed(let p, _): "f\(p.pid)"
            }
        }
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: request) { _, process in
                guard let process else { return }
                request = nil
                if let reason = ProcessTerminator.protectionReason(pid: process.pid, name: process.name, path: process.path) {
                    alert = .protected(process, reason)
                } else {
                    alert = .confirm(process)
                }
            }
            .alert(title, isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } }), presenting: alert) { current in
                switch current {
                case .confirm(let p):
                    Button("End Process", role: .destructive) { run(p, force: false) }
                    Button("Cancel", role: .cancel) {}
                case .stillRunning(let p):
                    Button("Force Quit", role: .destructive) { run(p, force: true) }
                    Button("Cancel", role: .cancel) {}
                case .protected, .failed:
                    Button("OK", role: .cancel) {}
                }
            } message: { current in
                switch current {
                case .confirm(let p):
                    Text(NSRunningApplication(processIdentifier: p.pid) != nil
                         ? "MacMonitor will ask \(p.name) to quit, the same as choosing Quit. It may ask you to save your work first."
                         : "MacMonitor will ask process \(p.pid) to exit (SIGTERM). Any work it hasn't saved may be lost.")
                case .protected(_, let reason):
                    Text(reason)
                case .stillRunning(let p):
                    Text("\(p.name) didn't quit within 5 seconds. It may be busy, or waiting for you (for example, a Save dialog).\n\nForce Quit ends it immediately: anything unsaved in it will be lost.")
                case .failed(_, let message):
                    Text(message)
                }
            }
    }

    private var title: String {
        switch alert {
        case .confirm(let p): "End “\(p.name)”?"
        case .protected(let p, _): "“\(p.name)” can't be ended"
        case .stillRunning(let p): "“\(p.name)” is still running"
        case .failed(let p, _): "Couldn't end “\(p.name)”"
        case nil: ""
        }
    }

    private func run(_ process: ProcessEntry, force: Bool) {
        Task {
            // Check again right before acting: the list may be a few seconds old.
            if let reason = ProcessTerminator.protectionReason(pid: process.pid, name: process.name, path: process.path) {
                alert = .protected(process, reason)
                return
            }
            guard ProcessTerminator.isSameProcess(process) else {
                await vm.refreshProcessesNow()
                alert = .failed(process, "\(process.name) has already exited. Nothing was ended.")
                return
            }
            let outcome = force ? await ProcessTerminator.forceEnd(pid: process.pid)
                                : await ProcessTerminator.endGracefully(pid: process.pid)
            await vm.refreshProcessesNow()
            switch outcome {
            case .ended, .alreadyGone: break
            case .stillRunning:
                alert = force ? .failed(process, "macOS didn't end the process. It may be protected by the system.")
                              : .stillRunning(process)
            case .refused(let message):
                alert = .failed(process, message)
            }
        }
    }
}

extension View {
    func endProcessFlow(request: Binding<ProcessEntry?>) -> some View {
        modifier(EndProcessFlow(request: request))
    }
}
