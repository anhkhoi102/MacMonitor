import SwiftUI

/// Internet speed test card on the Network page.
/// Nothing happens until the user presses "Run Speed Test".
struct SpeedTestCard: View {
    @Environment(DashboardViewModel.self) private var vm

    var body: some View {
        Card(title: "Internet Speed Test", systemImage: "speedometer", tint: .indigo) {
            let result = vm.lastSpeedTest
            HStack(spacing: 12) {
                tile("Download", result.map { String(format: "%.1f", $0.downloadMbps) }, "Mbps", "arrow.down.circle.fill", .green)
                tile("Upload", result.map { String(format: "%.1f", $0.uploadMbps) }, "Mbps", "arrow.up.circle.fill", .cyan)
                tile("Ping", result.map { String(format: "%.0f", $0.pingMs) }, "ms", "timer", .indigo)
                tile("Jitter", result.map { String(format: "%.1f", $0.jitterMs) }, "ms", "waveform.path", .purple)
            }
            .opacity(isRunning ? 0.45 : 1)

            statusArea(result)

            HStack(alignment: .center) {
                Text("Runs only when you click the button – never in the background. Uses Cloudflare's public speed-test servers and up to about 210 MB of data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 16)
                if isRunning {
                    Button("Cancel", role: .cancel) { vm.cancelSpeedTest() }
                } else {
                    Button(result == nil ? "Run Speed Test" : "Run Again") { vm.startSpeedTest() }
                        .buttonStyle(.borderedProminent)
                        .tint(.indigo)
                }
            }
        }
    }

    private var isRunning: Bool {
        if case .running = vm.speedTestState { return true }
        return false
    }

    @ViewBuilder
    private func statusArea(_ result: SpeedTestResult?) -> some View {
        switch vm.speedTestState {
        case .running(let progress):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(progress.phase.rawValue + "…").font(.callout.weight(.medium))
                    Spacer()
                    if let mbps = progress.currentMbps {
                        Text(String(format: "%.1f Mbps", mbps))
                            .font(.callout.weight(.semibold)).monospacedDigit()
                            .contentTransition(.numericText())
                    }
                }
                ProgressView(value: progress.fraction)
                    .tint(.indigo)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
        case .cancelled:
            Label("Test canceled. No result was saved.", systemImage: "xmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .idle:
            if let result {
                HStack(spacing: 16) {
                    Label(result.serverDescription, systemImage: "server.rack")
                    Label(result.date.formatted(date: .abbreviated, time: .shortened), systemImage: "clock")
                    Label("\(Fmt.storage(UInt64(result.bytesTransferred))) used", systemImage: "arrow.up.arrow.down")
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("No test run yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func tile(_ title: String, _ value: String?, _ unit: String, _ icon: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon).font(.caption.weight(.medium)).foregroundStyle(tint)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value ?? "—")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
}
