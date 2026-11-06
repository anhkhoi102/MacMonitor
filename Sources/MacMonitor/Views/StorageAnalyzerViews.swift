import SwiftUI

/// "Disk Space Analyzer" card on the Storage page. Read-only: it shows what
/// uses space and where; it has no way to delete anything.
struct DiskAnalyzerCard: View {
    @Environment(DashboardViewModel.self) private var vm
    @ViewState private var mode = Mode.applications
    @ViewState private var search = ""
    @ViewState private var typeFilter: StorageEntry.Kind?
    @ViewState private var appSort = [KeyPathComparator(\StorageEntry.totalSizeForSorting, order: .reverse)]
    @ViewState private var folderSort = [KeyPathComparator(\StorageEntry.totalSizeForSorting, order: .reverse)]
    @ViewState private var selection: StorageEntry.ID?
    @ViewState private var inspected: StorageEntry?

    enum Mode: String, CaseIterable { case applications = "Applications", folders = "Folders" }

    var body: some View {
        Card(title: "Disk Space Analyzer", systemImage: "chart.bar.doc.horizontal", tint: .orange) {
            HStack {
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                Spacer()
                if vm.isAnalyzing {
                    Button("Cancel", role: .cancel) { vm.cancelAnalysis() }
                }
            }

            progressOrError

            switch mode {
            case .applications: applicationsSection
            case .folders: foldersSection
            }

            Text("Read-only: the analyzer measures and shows locations, it never deletes. Use “Show in Finder” to act on an item yourself.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(item: $inspected) { StorageItemSheet(entry: $0) }
    }

    @ViewBuilder
    private var progressOrError: some View {
        switch vm.analyzerState {
        case .running(let progress):
            HStack {
                ProgressView().controlSize(.small)
                Text(progress.current.isEmpty ? "Starting…" : "Measuring \(progress.current)…").lineLimit(1)
                Spacer()
                Text("\(progress.filesSeen.formatted()) files").monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .cancelled:
            Label("Analysis canceled.", systemImage: "xmark.circle").foregroundStyle(.secondary)
        case .idle:
            EmptyView()
        }
    }

    // MARK: Applications

    @ViewBuilder
    private var applicationsSection: some View {
        if let analysis = vm.appAnalysis {
            let apps = analysis.entries.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
                .sorted(using: appSort)
            let appTotal = analysis.entries.reduce(0) { $0 + $1.size }
            let dataTotal = analysis.entries.reduce(0) { $0 + ($1.userDataSize ?? 0) }
            HStack {
                Text("\(analysis.entries.count) apps · \(Fmt.storage(analysis.totalSize)) (apps \(Fmt.storage(appTotal)) + user data \(Fmt.storage(dataTotal)))")
                    .font(.callout)
                Spacer()
                searchField
                Button("Rescan") { vm.analyzeApplications() }.disabled(vm.isAnalyzing)
            }
            Table(apps, selection: $selection, sortOrder: $appSort) {
                TableColumn("Name", value: \.name) { entry in
                    HStack(spacing: 6) {
                        AppIconView(bundlePath: entry.path).scaleEffect(0.7).frame(width: 18, height: 18)
                        Text(entry.name).lineLimit(1)
                    }
                }
                .width(min: 150, ideal: 200)
                TableColumn("Type") { Text($0.kind.rawValue).foregroundStyle(.secondary) }.width(78)
                TableColumn("Storage Used", value: \.totalSizeForSorting) { Text(Fmt.storage($0.totalSize)).monospacedDigit() }.width(88)
                TableColumn("App") { Text(Fmt.storage($0.size)).monospacedDigit().foregroundStyle(.secondary) }.width(72)
                TableColumn("User Data (est.)") { Text(Fmt.storage($0.userDataSize ?? 0)).monospacedDigit().foregroundStyle(.secondary) }.width(96)
                TableColumn("Last Opened", value: \.lastOpenedForSorting) { entry in
                    Text(entry.lastOpened.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "Unknown")
                        .foregroundStyle(entry.lastOpened == nil ? .secondary : .primary)
                }
                .width(96)
                TableColumn("Location") { Text(abbreviatedPath($0.url.deletingLastPathComponent())).foregroundStyle(.secondary).lineLimit(1) }
            }
            .frame(height: 380)
            .contextMenu(forSelectionType: StorageEntry.ID.self) { ids in menu(ids, in: analysis) }
                primaryAction: { ids in inspect(ids, in: analysis) }
            notes(analysis)
        } else {
            startPrompt(
                text: "Measures every app in /Applications and ~/Applications, estimates its data in your Library, and shows when you last opened it. Takes a few seconds.",
                button: "Analyze Applications") { vm.analyzeApplications() }
        }
    }

    // MARK: Folders

    @ViewBuilder
    private var foldersSection: some View {
        let home = FileManager.default.homeDirectoryForCurrentUser
        HStack(spacing: 8) {
            ForEach(["Downloads", "Documents", "Desktop", "Movies"], id: \.self) { name in
                Button(name) { vm.analyzeFolder(home.appending(path: name)) }
            }
            Button("Home Folder") { vm.analyzeFolder(home) }
            Button("Choose Folder…") { chooseFolder() }
            Spacer()
        }
        .controlSize(.small)
        .disabled(vm.isAnalyzing)

        if let folder = vm.analyzerFolder, let analysis = vm.folderAnalyses[folder] {
            let rows = analysis.entries
                .filter { typeFilter == nil || $0.kind == typeFilter }
                .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
                .sorted(using: folderSort)
            HStack(spacing: 8) {
                Button { vm.analyzeFolder(folder.deletingLastPathComponent()) } label: { Image(systemName: "chevron.up") }
                    .help("Go to the enclosing folder").disabled(folder.path == "/" || vm.isAnalyzing)
                Text(abbreviatedPath(folder)).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text("· \(Fmt.storage(analysis.totalSize))").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Picker("Type", selection: $typeFilter) {
                    Text("All types").tag(StorageEntry.Kind?.none)
                    ForEach(StorageEntry.Kind.allCases, id: \.self) { Text($0.rawValue + "s").tag(Optional($0)) }
                }
                .labelsHidden().frame(width: 130)
                searchField
                Button("Rescan") { vm.analyzeFolder(folder, forceRescan: true) }.disabled(vm.isAnalyzing)
            }
            Table(rows, selection: $selection, sortOrder: $folderSort) {
                TableColumn("Name", value: \.name) { entry in
                    Label(entry.name, systemImage: entry.kind == .folder ? "folder" : entry.kind == .application ? "app" : "doc")
                        .lineLimit(1)
                }
                .width(min: 160, ideal: 240)
                TableColumn("Type") { Text($0.kind.rawValue).foregroundStyle(.secondary) }.width(78)
                TableColumn("Storage Used", value: \.totalSizeForSorting) { Text(Fmt.storage($0.totalSize)).monospacedDigit() }.width(88)
                TableColumn("Last Opened", value: \.lastOpenedForSorting) { entry in
                    Text(entry.lastOpened.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "Not available")
                        .foregroundStyle(entry.lastOpened == nil ? .secondary : .primary)
                }
                .width(96)
                TableColumn("Modified", value: \.modifiedForSorting) { entry in
                    Text(entry.modified.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—").foregroundStyle(.secondary)
                }
                .width(96)
                TableColumn("Location") { Text(abbreviatedPath($0.url.deletingLastPathComponent())).foregroundStyle(.secondary).lineLimit(1) }
            }
            .frame(height: 380)
            .contextMenu(forSelectionType: StorageEntry.ID.self) { ids in menu(ids, in: analysis) }
                primaryAction: { ids in
                    // Double-click a folder to look inside it; anything else shows details.
                    if let entry = entry(ids, in: analysis), entry.kind == .folder { vm.analyzeFolder(entry.url) }
                    else { inspect(ids, in: analysis) }
                }
            Text("Double-click a folder to look inside. “Last Opened” comes from Spotlight; “Modified” is when the contents last changed.")
                .font(.caption).foregroundStyle(.secondary)
            notes(analysis)
        } else if !vm.isAnalyzing {
            startPrompt(text: "Pick a folder above. Its contents are listed by size, largest first. Nothing scans the whole disk, and nothing runs until you choose.",
                        button: nil) {}
        }
    }

    // MARK: Shared pieces

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $search).textFieldStyle(.plain).frame(width: 120)
        }
        .padding(5)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }

    private func startPrompt(text: String, button: String?, action: @escaping () -> Void) -> some View {
        HStack {
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 16)
            if let button {
                Button(button, action: action).buttonStyle(.borderedProminent).tint(.orange).disabled(vm.isAnalyzing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func notes(_ analysis: StorageAnalysis) -> some View {
        Text((analysis.notes + ["Measured \(analysis.date.formatted(date: .omitted, time: .shortened)) in \(analysis.duration.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow, maximumUnitCount: 1)))."]).joined(separator: " "))
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func menu(_ ids: Set<StorageEntry.ID>, in analysis: StorageAnalysis) -> some View {
        if let entry = entry(ids, in: analysis) {
            Button("Inspect") { inspected = entry }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.path, forType: .string)
            }
            if entry.kind == .folder {
                Divider()
                Button("Analyze This Folder") { vm.analyzeFolder(entry.url); mode = .folders }
            }
        }
    }

    private func entry(_ ids: Set<StorageEntry.ID>, in analysis: StorageAnalysis) -> StorageEntry? {
        ids.first.flatMap { id in analysis.entries.first { $0.id == id } }
    }

    private func inspect(_ ids: Set<StorageEntry.ID>, in analysis: StorageAnalysis) {
        inspected = entry(ids, in: analysis)
    }

    /// Standard macOS folder picker. Choosing a folder here is also how macOS
    /// lets MacMonitor read it.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Analyze"
        panel.message = "Choose a folder to measure. MacMonitor only reads it."
        if panel.runModal() == .OK, let url = panel.url {
            vm.analyzeFolder(url, forceRescan: true)
        }
    }
}

/// "Inspect": everything known about one item.
struct StorageItemSheet: View {
    @Environment(\.dismiss) private var dismiss
    let entry: StorageEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: entry.path)).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.title3.weight(.semibold))
                    Text(entry.kind.rawValue).foregroundStyle(.secondary)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow { Text("Location").foregroundStyle(.secondary); Text(entry.path).textSelection(.enabled) }
                if entry.kind == .application {
                    GridRow { Text("App bundle").foregroundStyle(.secondary); Text("\(Fmt.storage(entry.size)) · \(entry.fileCount.formatted()) files") }
                    GridRow { Text("User data (est.)").foregroundStyle(.secondary); Text(Fmt.storage(entry.userDataSize ?? 0)) }
                    GridRow { Text("Total").foregroundStyle(.secondary); Text(Fmt.storage(entry.totalSize)).fontWeight(.semibold) }
                    if let id = entry.bundleIdentifier {
                        GridRow { Text("Bundle ID").foregroundStyle(.secondary); Text(id).textSelection(.enabled) }
                    }
                } else {
                    GridRow { Text("Size").foregroundStyle(.secondary)
                        Text(entry.kind == .file ? Fmt.storage(entry.size) : "\(Fmt.storage(entry.size)) · \(entry.fileCount.formatted()) files") }
                }
                GridRow { Text("Last opened").foregroundStyle(.secondary)
                    Text(entry.lastOpened?.formatted(date: .long, time: .shortened) ?? "Not available (macOS has no record)") }
                GridRow { Text("Last modified").foregroundStyle(.secondary)
                    Text(entry.modified?.formatted(date: .long, time: .shortened) ?? "Unknown") }
            }
            if !entry.userDataPaths.isEmpty {
                Text("User data counted").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(entry.userDataPaths, id: \.self) { url in
                        HStack {
                            Text(abbreviatedPath(url)).font(.callout).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.controlSize(.small)
                        }
                    }
                }
            }
            Text("“Last opened” is when macOS last recorded the item being opened (Spotlight). “Last modified” is when its contents changed. They are different things.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 560)
    }
}
