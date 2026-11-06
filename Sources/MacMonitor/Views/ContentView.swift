import SwiftUI

/// The pages shown in the sidebar.
enum SidebarItem: String, CaseIterable, Identifiable {
    case overview, cpu, memory, storage, network, battery, processes, information, power, cleaner, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .cpu: "CPU"
        case .memory: "Memory"
        case .storage: "Storage"
        case .network: "Network"
        case .battery: "Battery"
        case .processes: "Processes"
        case .information: "Information"
        case .power: "Power"
        case .cleaner: "Cleaner"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .storage: "internaldrive"
        case .network: "network"
        case .battery: "battery.75percent"
        case .processes: "list.bullet.rectangle"
        case .information: "info.circle"
        case .power: "power"
        case .cleaner: "sparkles"
        case .settings: "gearshape"
        }
    }

    static let monitors: [SidebarItem] = [.overview, .cpu, .memory, .storage, .network, .battery, .processes]
    static let system: [SidebarItem] = [.information, .power]
    static let tools: [SidebarItem] = [.cleaner, .settings]
}

/// Root view: a two-column layout with a sidebar and a detail page.
struct ContentView: View {
    @Environment(DashboardViewModel.self) private var viewModel
    @AppStorage(SettingsKey.appearance) private var appearance = AppearanceMode.system.rawValue

    var body: some View {
        @Bindable var viewModel = viewModel
        NavigationSplitView {
            List(selection: $viewModel.selectedPage) {
                Section("Monitor") {
                    ForEach(SidebarItem.monitors) { item in
                        Label(item.title, systemImage: item.systemImage).tag(item)
                    }
                }
                Section("System") {
                    ForEach(SidebarItem.system) { item in
                        Label(item.title, systemImage: item.systemImage).tag(item)
                    }
                }
                Section("Tools") {
                    ForEach(SidebarItem.tools) { item in
                        Label(item.title, systemImage: item.systemImage).tag(item)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
                .navigationTitle(viewModel.selectedPage?.title ?? "MacMonitor")
        }
        // Start the refresh loop. SwiftUI cancels it when the window closes.
        .task { await viewModel.run() }
        // Developer option: MACMONITOR_START_PAGE=memory opens that page at launch
        // (used to measure each page's CPU cost).
        .onAppear {
            if let page = ProcessInfo.processInfo.environment["MACMONITOR_START_PAGE"].flatMap(SidebarItem.init(rawValue:)) {
                viewModel.selectedPage = page
            }
            // Developer option: MACMONITOR_DEV_FRONT=1 brings the window to the
            // front at launch, so measurements see a visible (not covered) window.
            if ProcessInfo.processInfo.environment["MACMONITOR_DEV_FRONT"] != nil {
                Task {
                    try? await Task.sleep(for: .seconds(0.5))
                    NSApp.activate()
                    NSApp.windows.first { $0.isVisible }?.orderFrontRegardless()
                    try? await Task.sleep(for: .seconds(3))
                    if let path = ProcessInfo.processInfo.environment["MACMONITOR_DEV_VISLOG"] {
                        let state = NSApp.windows.map { "\(type(of: $0)) visible=\($0.isVisible) onActiveSpace=\($0.isOnActiveSpace) occlusionVisible=\($0.occlusionState.contains(.visible)) key=\($0.isKeyWindow) frame=\(Int($0.frame.width))x\(Int($0.frame.height))" }
                            .joined(separator: "\n") + "\nappActive=\(NSApp.isActive) monitoringPaused=\(!viewModel.isWindowVisible)\n"
                        try? state.write(toFile: path, atomically: true, encoding: .utf8)
                    }
                }
            }
            // Developer option: MACMONITOR_DEV_BACKGROUND=hide|minimize hides or
            // minimizes the window after 3 s (used to measure background CPU use).
            if let mode = ProcessInfo.processInfo.environment["MACMONITOR_DEV_BACKGROUND"] {
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    NSApp.activate()
                    try? await Task.sleep(for: .seconds(1))
                    if mode == "hide" { NSApp.hide(nil) }
                    else { NSApp.windows.first { $0.isVisible }?.performMiniaturize(nil) }
                    try? await Task.sleep(for: .seconds(2))
                    if let path = ProcessInfo.processInfo.environment["MACMONITOR_DEV_VISLOG"] {
                        let state = "mode=\(mode) hidden=\(NSApp.isHidden) miniaturized=\(NSApp.windows.contains { $0.isMiniaturized }) monitoringPaused=\(!viewModel.isWindowVisible)\n"
                        try? state.write(toFile: path, atomically: true, encoding: .utf8)
                    }
                }
            }
        }
        // Developer screenshot mode (no-op unless MACMONITOR_SNAPSHOT_DIR is set).
        .task { await SnapshotExporter.runIfRequested { viewModel.selectedPage = $0 } }
        .task { await SnapshotExporter.runSpeedTestIfRequested(vm: viewModel) { viewModel.selectedPage = $0 } }
        .task { await SnapshotExporter.runScanIfRequested(vm: viewModel) { viewModel.selectedPage = $0 } }
        .task { await SnapshotExporter.runCleanupSelfTestIfRequested(vm: viewModel) { viewModel.selectedPage = $0 } }
        .task { await SnapshotExporter.runAnalyzerIfRequested(vm: viewModel) { viewModel.selectedPage = $0 } }
        .task { await SnapshotExporter.runInformationIfRequested(vm: viewModel) { viewModel.selectedPage = $0 } }
        // Pause monitoring while no MacMonitor window can be seen.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { _ in
            updateVisibility()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didHideNotification)) { _ in
            viewModel.setWindowVisible(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didUnhideNotification)) { _ in
            updateVisibility()
        }
        // macOS may restore the window minimized from the last launch. A
        // dashboard should open visible, so bring it back once at launch, then
        // check visibility (no "changed" notification arrives in that case).
        .task {
            for window in NSApp.windows where window.isMiniaturized { window.deminiaturize(nil) }
            try? await Task.sleep(for: .seconds(1))
            updateVisibility()
        }
        .onChange(of: appearance) { _, newValue in
            (AppearanceMode(rawValue: newValue) ?? .system).apply()
        }
    }

    /// Can any MacMonitor window actually be seen right now?
    private func updateVisibility() {
        let visible = !NSApp.isHidden && NSApp.windows.contains {
            $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
        }
        viewModel.setWindowVisible(visible)
    }

    @ViewBuilder
    private var detail: some View {
        @Bindable var viewModel = viewModel
        switch viewModel.selectedPage ?? .overview {
        case .overview: DashboardView(selection: $viewModel.selectedPage)
        case .cpu: CPUView()
        case .memory: MemoryView()
        case .storage: StorageView()
        case .network: NetworkView()
        case .battery: BatteryView()
        case .processes: ProcessesView()
        case .information: InformationView()
        case .power: PowerView()
        case .cleaner: CleanerView()
        case .settings: SettingsView()
        }
    }
}
