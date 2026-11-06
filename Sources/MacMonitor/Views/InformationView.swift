import SwiftUI

/// Information page: this Mac, its macOS, available updates and their
/// security content. Local facts refresh every time the page opens; Apple's
/// online data is cached for 12 hours (Refresh forces both).
struct InformationView: View {
    @Environment(DashboardViewModel.self) private var vm
    @ViewState private var showSerial = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    PageHeader(title: "Information", subtitle: "This Mac, its macOS version and available updates")
                    VStack(alignment: .trailing, spacing: 4) {
                        Button {
                            Task { await vm.refreshInformation(force: true) }
                        } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                            .disabled(vm.updateFetchState == .loading)
                        if let date = vm.informationRefreshedAt {
                            Text("Updated \(date.formatted(date: .omitted, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                if let info = vm.systemInfo {
                    HStack(alignment: .top, spacing: 16) {
                        macOSCard(info)
                        macCard(info)
                    }
                    updateCard(info)
                    securityCard(info)
                } else {
                    ProgressView("Reading system information…").frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(24)
        }
        .task { await vm.refreshInformation(force: false) }
    }

    /// Update data is shown only if it was fetched for this Mac and this macOS version.
    private func currentUpdateInfo(_ info: SystemInfo) -> MacOSUpdateInfo? {
        guard let cached = vm.updateInfo, cached.boardID == info.boardID, cached.installedVersion == info.osVersion else { return nil }
        return cached
    }

    // MARK: macOS

    private func macOSCard(_ info: SystemInfo) -> some View {
        let name = currentUpdateInfo(info)?.releaseNames[String(MacOSUpdateService.major(of: info.osVersion) ?? 0)]
            ?? Self.knownNames[MacOSUpdateService.major(of: info.osVersion) ?? 0]
        return Card(title: "macOS", systemImage: "apple.logo", tint: .blue) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 9) {
                row("Version", "macOS \(info.osVersion)")
                if let name { row("Release name", name) }
                row("Build", info.osBuild)
                row("Kernel", info.kernelVersion)
                if let boot = info.bootDate {
                    row("Uptime", SystemUptimeService.formatUptime(from: boot))
                    row("Last boot", boot.formatted(date: .abbreviated, time: .shortened))
                }
            }
        }
    }

    /// Names Apple has used; newer ones come from Apple's security page.
    static let knownNames: [Int: String] = [11: "Big Sur", 12: "Monterey", 13: "Ventura", 14: "Sonoma", 15: "Sequoia", 26: "Tahoe"]

    // MARK: Mac

    private func macCard(_ info: SystemInfo) -> some View {
        Card(title: "This Mac", systemImage: "laptopcomputer", tint: .gray) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 9) {
                if let model = info.modelName { row("Model", model) }
                row("Model identifier", info.modelIdentifier)
                row("Chip", info.chip)
                row("CPU cores", info.coreDescription)
                row("Memory", Fmt.memoryGB(info.memoryBytes, decimals: 0))
                if let gpu = info.gpuName {
                    row("Graphics", info.gpuCores.map { "\(gpu) · \($0)-core GPU" } ?? gpu)
                }
                row("Architecture", info.architecture)
                row("Storage", "\(Fmt.storage(vm.disk.available)) available of \(Fmt.storage(vm.disk.total))")
                if let serial = info.serialNumber {
                    GridRow {
                        Text("Serial number").foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            // Hidden by default: a serial number identifies this exact Mac.
                            Text(showSerial ? serial : String(repeating: "•", count: 10))
                                .monospaced().textSelection(.enabled)
                            Button(showSerial ? "Hide" : "Show") { showSerial.toggle() }
                                .buttonStyle(.link).font(.caption)
                        }
                    }
                }
            }
        }
    }

    // MARK: Software update

    @ViewBuilder
    private func updateCard(_ info: SystemInfo) -> some View {
        Card(title: "Software Update", systemImage: "arrow.down.circle", tint: .green) {
            if let update = currentUpdateInfo(info) {
                let compatible = update.latestCompatible
                let available = compatible.map { MacOSUpdateService.isNewer($0.version, than: info.osVersion) } ?? false
                HStack(spacing: 10) {
                    Label(available ? "Update available" : "Up to date",
                          systemImage: available ? "arrow.down.circle.fill" : "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundStyle(available ? .orange : .green)
                    Spacer()
                    Button("Open Software Update") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!)
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 9) {
                    row("Installed", "macOS \(info.osVersion) (\(info.osBuild))")
                    if let compatible {
                        row("Latest for this Mac", "macOS \(compatible.version) (\(compatible.build))" + dateSuffix(compatible.postingDate))
                    } else {
                        row("Latest for this Mac", "Not found in Apple's catalog")
                    }
                    if let latest = update.latestReleased {
                        let same = latest.version == compatible?.version
                        row("Latest released by Apple",
                            "macOS \(latest.version)" + dateSuffix(latest.postingDate) + (same ? " – supports this Mac" : " – not available for this Mac"))
                    }
                }
                Text("“Latest for this Mac” comes from Apple's software update catalog, which lists the exact Macs each release supports. Checked \(update.fetchedAt.formatted(date: .abbreviated, time: .shortened)).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            onlineStatus
        }
    }

    @ViewBuilder
    private var onlineStatus: some View {
        switch vm.updateFetchState {
        case .loading:
            HStack { ProgressView().controlSize(.small); Text("Checking with Apple…").foregroundStyle(.secondary) }.font(.callout)
        case .failed(let message):
            Label("Online information unavailable: \(message) Local information is still shown.", systemImage: "wifi.exclamationmark")
                .font(.callout).foregroundStyle(.orange)
        case .idle:
            EmptyView()
        }
    }

    // MARK: Security

    @ViewBuilder
    private func securityCard(_ info: SystemInfo) -> some View {
        if let update = currentUpdateInfo(info) {
            let available = update.latestCompatible.map { MacOSUpdateService.isNewer($0.version, than: info.osVersion) } ?? false
            let priority = MacOSUpdateService.priority(for: update.securityReleases, updateAvailable: available)
            Card(title: "Security and Fixes", systemImage: "lock.shield", tint: priorityColor(priority)) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(priority.rawValue)
                        .font(.headline)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .foregroundStyle(priorityColor(priority))
                        .background(priorityColor(priority).opacity(0.14), in: Capsule())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(priority.meaning).font(.callout)
                        Text("Why: " + MacOSUpdateService.priorityReason(for: update.securityReleases, updateAvailable: available))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if update.securityReleases.isEmpty {
                    Text(available ? "Apple hasn't published security notes for the newer release yet." : "macOS \(info.osVersion) has all security fixes Apple has published for this Mac.")
                        .font(.callout)
                }
                ForEach(update.securityReleases, id: \.version) { release in
                    releaseSummary(release, installed: info.osVersion)
                }
                Text("From Apple Security Releases. Apple doesn't publish bug fixes and known issues in a form MacMonitor can read reliably. See the notes in Software Update before installing.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func releaseSummary(_ release: SecurityRelease, installed: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Text(release.title).font(.callout.weight(.semibold))
                Text("· \(release.releaseDate)").font(.callout).foregroundStyle(.secondary)
                Spacer()
                if let link = release.url, let url = URL(string: link) {
                    Link("Apple's security notes", destination: url).font(.callout)
                }
            }
            Text(release.issueCount > 0
                 ? "Fixes \(release.issueCount) security issues (\(release.cveIDs.count) CVEs). Your macOS \(installed) is affected: install \(release.version) or later to get these fixes."
                 : "No published CVE entries for this update.")
                .font(.callout)
            if release.exploitedInTheWild {
                Label("Apple reports that at least one of these issues may have been actively exploited.", systemImage: "exclamationmark.octagon.fill")
                    .font(.callout.weight(.medium)).foregroundStyle(.red)
            }
            ForEach(release.groups) { group in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Example: \(group.example)").font(.caption)
                        Text(group.cveIDs.prefix(12).joined(separator: ", ") + (group.cveIDs.count > 12 ? " and \(group.cveIDs.count - 12) more" : ""))
                            .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    .padding(.leading, 4)
                } label: {
                    HStack {
                        Text(group.category.rawValue)
                        Spacer()
                        Text("\(group.count)").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
    }

    // MARK: Helpers

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
        .font(.callout)
    }

    private func dateSuffix(_ date: Date?) -> String {
        date.map { ", released \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
    }

    private func priorityColor(_ priority: UpdatePriority) -> Color {
        switch priority {
        case .critical: .red
        case .high: .orange
        case .medium: .yellow
        case .low: .green
        }
    }
}

/// Power page: Restart, Shut Down, Sleep, Lock Screen.
struct PowerView: View {
    @ViewState private var confirming: PowerService.Action?
    @ViewState private var errorMessage: String?

    private var actions: [PowerService.Action] {
        PowerService.Action.allCases.filter { $0 != .lock || PowerService.isLockAvailable }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Power", subtitle: "Restart, shut down, sleep or lock this Mac")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16)], spacing: 16) {
                    ForEach(actions) { action in
                        Button {
                            if action.needsConfirmation { confirming = action } else { run(action) }
                        } label: {
                            VStack(spacing: 12) {
                                Image(systemName: action.systemImage)
                                    .font(.system(size: 30, weight: .medium))
                                    .foregroundStyle(action == .shutDown ? .red : .accentColor)
                                    .frame(height: 36)
                                Text(action.rawValue).font(.headline)
                                Text(action.explanation)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(18)
                            .frame(maxWidth: .infinity, minHeight: 170, alignment: .top)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(action.explanation)
                    }
                }
                Text("These use the same requests as the Apple menu and need no administrator rights. The first time you restart or shut down from here, macOS may ask to let MacMonitor control “loginwindow”.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
        }
        .confirmationDialog(confirming.map { "\($0.rawValue) this Mac?" } ?? "",
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            presenting: confirming) { action in
            Button(action.rawValue, role: .destructive) { run(action) }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(action.explanation + " Save your work first.")
        }
        .alert("Couldn't complete the request", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func run(_ action: PowerService.Action) {
        errorMessage = PowerService.perform(action)
    }
}
