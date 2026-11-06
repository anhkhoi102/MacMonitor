import SwiftUI

/// Preferences are stored with @AppStorage, a SwiftUI wrapper around
/// UserDefaults. Changing a control saves it immediately.
struct SettingsView: View {
    @AppStorage(SettingsKey.appearance) private var appearance = AppearanceMode.system.rawValue
    @AppStorage(SettingsKey.cpuInterval) private var cpuInterval = SettingsDefaults.cpuInterval
    @AppStorage(SettingsKey.memoryInterval) private var memoryInterval = SettingsDefaults.memoryInterval
    @AppStorage(SettingsKey.networkInterval) private var networkInterval = SettingsDefaults.networkInterval
    @AppStorage(SettingsKey.diskInterval) private var diskInterval = SettingsDefaults.diskInterval
    @AppStorage(SettingsKey.historySeconds) private var historySeconds = SettingsDefaults.historySeconds
    @AppStorage(SettingsKey.speedUnit) private var speedUnit = NetworkSpeedUnit.megabytesPerSecond.rawValue
    /// Mirrors the real macOS setting (see LaunchAtLogin).
    @ViewState private var launchAtLogin = LaunchAtLogin.isEnabled
    @ViewState private var launchAtLoginMessage: String?

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
            }

            Section {
                intervalPicker("CPU", $cpuInterval, [1, 2, 5])
                intervalPicker("Memory", $memoryInterval, [1, 2, 5])
                intervalPicker("Network", $networkInterval, [1, 2, 5])
                intervalPicker("Disk capacity", $diskInterval, [10, 30, 60])
                Picker("Chart history", selection: $historySeconds) {
                    Text("1 minute").tag(60)
                    Text("2 minutes").tag(120)
                    Text("5 minutes").tag(300)
                }
            } header: {
                Text("Monitoring")
            } footer: {
                Text("Longer intervals use less CPU. Changes apply on the next refresh.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Network speed unit", selection: $speedUnit) {
                    ForEach(NetworkSpeedUnit.allCases) { Text($0.title).tag($0.rawValue) }
                }
            } header: {
                Text("Display")
            } footer: {
                Text("Temperature isn't shown: macOS doesn't share sensor temperatures with regular apps.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                if let launchAtLoginMessage {
                    HStack {
                        Text(launchAtLoginMessage).font(.callout).foregroundStyle(.orange)
                        Spacer()
                        Button("Open Login Items…") { LaunchAtLogin.openSystemSettings() }
                    }
                }
            } header: {
                Text("Startup")
            } footer: {
                Text("Off by default. Works from the packaged MacMonitor.app (best from the Applications folder). You can also manage it in System Settings › General › Login Items.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Cleanup method", value: "Move to Trash")
                LabeledContent("Automatic cleanup", value: "Never")
                LabeledContent("Scheduled cleanup", value: "Never")
                LabeledContent("Confirmation", value: "Always required")
            } header: {
                Text("Storage Cleaner")
            } footer: {
                Text("These safety rules are fixed and cannot be turned off.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)   // blend with the window background
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity)
        .navigationTitle("Settings")
        .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.set(enabled)
            launchAtLoginMessage = LaunchAtLogin.needsApproval
                ? "macOS needs your approval in System Settings › Login Items." : nil
        } catch {
            launchAtLoginMessage = "macOS didn't allow this: \(error.localizedDescription)"
        }
        launchAtLogin = LaunchAtLogin.isEnabled   // always show the real state
    }

    private func intervalPicker(_ title: String, _ binding: Binding<Double>, _ options: [Double]) -> some View {
        Picker(title, selection: binding) {
            ForEach(options, id: \.self) { Text("\(Int($0)) s").tag($0) }
        }
    }
}
