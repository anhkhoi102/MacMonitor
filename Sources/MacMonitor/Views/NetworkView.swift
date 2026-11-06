import SwiftUI

struct NetworkView: View {
    @Environment(DashboardViewModel.self) private var vm
    @AppStorage(SettingsKey.speedUnit) private var speedUnitRaw = NetworkSpeedUnit.megabytesPerSecond.rawValue

    @AppStorage(SettingsKey.networkInterval) private var networkInterval = SettingsDefaults.networkInterval

    private var unit: NetworkSpeedUnit { NetworkSpeedUnit(rawValue: speedUnitRaw) ?? .megabytesPerSecond }

    var body: some View {
        let n = vm.network
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Network", subtitle: "Real-time throughput and Internet speed test", showsMockBadge: vm.isMock(.network))

                // E1 – real-time monitoring
                HStack(spacing: 12) {
                    StatTile(title: "Download", value: Fmt.speed(n.downloadBytesPerSecond, unit: unit), systemImage: "arrow.down.circle.fill", tint: .green)
                    StatTile(title: "Upload", value: Fmt.speed(n.uploadBytesPerSecond, unit: unit), systemImage: "arrow.up.circle.fill", tint: .cyan)
                    StatTile(title: "Downloaded (session)", value: Fmt.storage(n.totalDownloaded), systemImage: "tray.and.arrow.down", tint: .green)
                    StatTile(title: "Uploaded (session)", value: Fmt.storage(n.totalUploaded), systemImage: "tray.and.arrow.up", tint: .cyan)
                }

                Card(title: "Throughput", systemImage: "waveform.path.ecg", tint: .green) {
                    DualHistoryChart(
                        first: vm.downloadHistory, second: vm.uploadHistory,
                        firstLabel: "Download", secondLabel: "Upload",
                        firstTint: .green, secondTint: .cyan,
                        showsAxes: true, showsLegend: true,
                        gridLabel: { [unit] in Fmt.speed($0, unit: unit) }, height: 220)
                    HStack {
                        Text("Last \(vm.historySeconds / 60) min")
                        Spacer()
                        Text("Updated every \(Int(networkInterval)) s")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Card(title: "Connection", systemImage: n.symbolName, tint: .green) {
                    ConnectionDetails(network: n)
                    Divider()
                    Text("“Session” totals count from when MacMonitor opened (macOS doesn't give apps exact all-time totals). Only physical network hardware (Wi-Fi, Ethernet) is counted; VPN tunnels and AirDrop links are skipped so traffic isn't counted twice. The live monitor only reads counters macOS already keeps – it sends no traffic of its own.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // E2 – Internet speed test (Phase 7), independent of the live monitor above.
                SpeedTestCard()

                DNSFlushCard()
            }
            .padding(24)
        }
        .task { await vm.monitorConnectionInfo() }
    }
}

/// Active interface, Wi-Fi name, local and public IPv4.
private struct ConnectionDetails: View {
    @Environment(DashboardViewModel.self) private var vm
    let network: NetworkStats

    var body: some View {
        let split = NetworkInfoService.split(vm.localAddresses, primaryInterface: network.isConnected ? network.interfaceName : nil)
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
            GridRow {
                label("Network Interface")
                Text(network.isConnected ? "\(network.interfaceType) (\(network.interfaceName))" : "Not connected")
                    .foregroundStyle(network.isConnected ? .primary : .secondary)
            }
            GridRow {
                label("Connected Wi-Fi")
                wifiValue
            }
            GridRow {
                label("Local IPv4")
                VStack(alignment: .leading, spacing: 3) {
                    Text(split.primary?.address ?? (network.isConnected ? "No IPv4 address" : "Not connected"))
                        .monospacedDigit().textSelection(.enabled)
                    ForEach(split.others) { other in
                        Text("\(other.kind) (\(other.interface)): \(other.address)")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit().textSelection(.enabled)
                    }
                }
            }
            GridRow {
                label("Public IPv4")
                publicIPValue
            }
        }
        .font(.callout)
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.leading)
    }

    @ViewBuilder
    private var wifiValue: some View {
        switch vm.wifi.state {
        case .connected(let ssid):
            Label(ssid, systemImage: "wifi").textSelection(.enabled)
        case .notConnected:
            Text(network.isConnected ? "Not on Wi-Fi (connected via \(network.interfaceType))" : "Not connected to Wi-Fi")
                .foregroundStyle(.secondary)
        case .wifiOff:
            Text("Wi-Fi is turned off").foregroundStyle(.secondary)
        case .noWiFiHardware:
            Text("This Mac has no Wi-Fi").foregroundStyle(.secondary)
        case .needsPermission:
            HStack(spacing: 10) {
                Text("Hidden by macOS").foregroundStyle(.secondary)
                Button("Allow Location Access…") { vm.wifi.requestPermission() }
                    .controlSize(.small)
                    .help("macOS only shares the Wi-Fi name with apps that have Location Services permission. MacMonitor uses it for nothing else and never reads your location.")
            }
        case .permissionDenied:
            HStack(spacing: 10) {
                Text("Hidden – Location Services is off for MacMonitor").foregroundStyle(.secondary)
                Button("Open Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
        case .nameHidden:
            Text("Connected, but macOS didn't share the network name").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var publicIPValue: some View {
        HStack(spacing: 10) {
            switch vm.publicIP {
            case .notLoaded:
                Text("Not looked up yet").foregroundStyle(.secondary)
            case .loading:
                ProgressView().controlSize(.small)
                Text("Looking up…").foregroundStyle(.secondary)
            case .loaded(let ip, let date):
                Text(ip).monospacedDigit().textSelection(.enabled)
                Text("as of \(date.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            case .failed(let message):
                Label("Couldn't get the public IP: \(message)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Button {
                Task { await vm.refreshPublicIP() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(vm.publicIP == .loading)
            .help("Look up again. Asks Cloudflare (https://1.1.1.1) which address your connection uses. Nothing else is sent. Done automatically at most every 15 minutes while this page is open.")
        }
    }
}

/// "Flush DNS Cache": confirmation → macOS admin dialog → honest result.
private struct DNSFlushCard: View {
    @Environment(DashboardViewModel.self) private var vm
    @ViewState private var confirming = false

    var body: some View {
        Card(title: "DNS Cache", systemImage: "arrow.triangle.2.circlepath", tint: .blue) {
            HStack(alignment: .center, spacing: 16) {
                Text("Clears the Mac's local list of recently looked-up website addresses, so names are looked up fresh. Can help when a site moved or after switching networks or VPNs.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button("Flush DNS Cache…") { confirming = true }
                    .disabled(vm.dnsFlushState == .running)
            }
            result
        }
        .confirmationDialog("Flush the DNS cache?", isPresented: $confirming) {
            Button("Flush DNS Cache") { Task { await vm.flushDNS() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears the local macOS DNS resolver cache (dscacheutil and mDNSResponder). Nothing else changes; websites may take a moment longer to open the first time.\n\nmacOS will ask for an administrator password or Touch ID. It goes to macOS, not to MacMonitor.")
        }
    }

    @ViewBuilder
    private var result: some View {
        switch vm.dnsFlushState {
        case .idle:
            EmptyView()
        case .running:
            HStack { ProgressView().controlSize(.small); Text("Waiting for macOS…").foregroundStyle(.secondary) }
                .font(.callout)
        case .finished(.flushed, let date):
            Label("DNS cache flushed at \(date.formatted(date: .omitted, time: .shortened)).", systemImage: "checkmark.circle.fill")
                .font(.callout).foregroundStyle(.green)
        case .finished(.cancelled, _):
            Label("Canceled. The DNS cache was not changed.", systemImage: "xmark.circle")
                .font(.callout).foregroundStyle(.secondary)
        case .finished(.failed(let message), _):
            Label("Couldn't flush the DNS cache: \(message)", systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(.orange)
        }
    }
}
