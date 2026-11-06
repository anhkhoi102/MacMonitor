import SwiftUI

// Reusable building blocks shared by every screen. Building the UI out of
// small components keeps each page short and the visual style consistent.

/// A rounded "card" container with an optional titled header.
struct Card<Content: View>: View {
    var title: String? = nil
    var systemImage: String? = nil
    var tint: Color = .accentColor
    /// Shows a small "Mock" tag while this card still uses simulated data.
    var isMock = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                HStack(spacing: 8) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .foregroundStyle(tint)
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 26, height: 26)
                            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
                    }
                    Text(title).font(.headline)
                    Spacer()
                    if isMock { MockBadge(text: "Mock", compact: true) }
                }
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07))
        )
    }
}

/// Large page title used at the top of each screen.
struct PageHeader: View {
    let title: String
    let subtitle: String
    var showsMockBadge = false
    var mockBadgeText = "Mock data"

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.largeTitle.weight(.bold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if showsMockBadge { MockBadge(text: mockBadgeText) }
        }
    }
}

/// Reminder that the numbers on screen are fake during Phase 2.
struct MockBadge: View {
    var text = "Mock data"
    var compact = false

    var body: some View {
        Label(text, systemImage: "wand.and.stars")
            .font((compact ? Font.caption2 : .caption).weight(.semibold))
            .padding(.horizontal, compact ? 7 : 10)
            .padding(.vertical, compact ? 3 : 5)
            .foregroundStyle(.orange)
            .background(.orange.opacity(0.14), in: Capsule())
            .help("Simulated values. Real monitoring is being added in Phases 3–6.")
    }
}

/// Circular utilization ring with the percentage in the middle.
struct RingGauge: View {
    /// 0–100
    let value: Double
    let tint: Color
    var lineWidth: CGFloat = 10
    var size: CGFloat = 96
    var caption: String? = nil

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, value / 100)))
                .stroke(
                    AngularGradient(colors: [tint.opacity(0.6), tint], center: .center),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(Fmt.percent(value))
                    .font(.system(size: size * 0.22, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if let caption {
                    Text(caption).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(caption ?? "Gauge")
        .accessibilityValue(Fmt.percent(value))
    }
}

/// Horizontal progress bar used for storage and memory.
struct UsageBar: View {
    /// 0–100
    let value: Double
    let tint: Color
    var height: CGFloat = 10
    /// Animate changes. Only worth it for values that change rarely (disk);
    /// per-second animations keep the GPU busy for little benefit.
    var animated = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.15))
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.75), tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * max(0, min(1, value / 100)))
                    .animation(animated ? .easeOut(duration: 0.3) : nil, value: value)
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Usage")
        .accessibilityValue(Fmt.percent(value))
    }
}

/// "Label ........ value" row with a coloured dot.
struct StatRow: View {
    let label: String
    let value: String
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: 8) {
            if let tint {
                Circle().fill(tint).frame(width: 8, height: 8)
            }
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).fontWeight(.medium).monospacedDigit()
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

/// Small tile showing one headline number.
struct StatTile: View {
    let title: String
    let value: String
    var systemImage: String
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
        // VoiceOver reads the tile as one item: "CPU Total, 23%".
        .accessibilityElement(children: .combine)
    }
}

/// A checkbox with three states – off, on, and "mixed" (–) when only some of
/// what it stands for is selected – like the macOS Finder and Mail.
struct TriStateCheckbox: View {
    let state: DashboardViewModel.CategorySelection
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: state == .all ? "checkmark.square.fill" : state == .some ? "minus.square.fill" : "square")
                .font(.system(size: 15))
                .foregroundStyle(state == .none ? Color.secondary : Color.accentColor)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Select \(title)")
        .accessibilityValue(state == .all ? "selected" : state == .some ? "partly selected" : "not selected")
    }
}
