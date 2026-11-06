import SwiftUI

/// One line on a `SparklineChart`.
struct ChartSeries {
    let points: [HistoryPoint]
    let color: Color
    var filled = false
    var dashed = false
}

/// A lightweight live line chart drawn with `Canvas`.
///
/// Why not Swift Charts? Charts creates and lays out one "mark" per data
/// point. Redrawing 4 charts × 120 points every second measured ~5% CPU on
/// an M1. `Canvas` just strokes one path per series – the same picture for a
/// fraction of the cost, which matters for an app that is always running.
/// (Swift Charts is still used for the static storage donut.)
struct SparklineChart: View {
    let series: [ChartSeries]
    /// Number of samples the X axis spans (the history length).
    let capacity: Int
    /// Fixed top of the Y axis (e.g. 100 for percentages); nil = auto-scale.
    var maxValue: Double? = nil
    /// Draw horizontal grid lines with value labels.
    var showsGrid = false
    var gridLabel: (Double) -> String = { String(format: "%.0f", $0) }
    var height: CGFloat = 70

    var body: some View {
        Canvas { context, size in
            let lastID = series.compactMap { $0.points.last?.id }.max() ?? 0
            let firstID = lastID - capacity + 1
            let peak = series.flatMap { $0.points.map(\.value) }.max() ?? 0
            let top = maxValue ?? max(peak * 1.15, 0.1)

            if showsGrid {
                drawGrid(in: &context, size: size, top: top)
            }

            func position(_ p: HistoryPoint) -> CGPoint {
                let x = size.width * CGFloat(p.id - firstID) / CGFloat(max(capacity - 1, 1))
                let y = size.height * (1 - CGFloat(min(max(p.value / top, 0), 1)))
                return CGPoint(x: x, y: y)
            }

            for s in series where s.points.count > 1 {
                var line = Path()
                line.move(to: position(s.points[0]))
                for p in s.points.dropFirst() { line.addLine(to: position(p)) }

                if s.filled {
                    var area = line
                    area.addLine(to: CGPoint(x: position(s.points.last!).x, y: size.height))
                    area.addLine(to: CGPoint(x: position(s.points[0]).x, y: size.height))
                    area.closeSubpath()
                    context.fill(area, with: .linearGradient(
                        Gradient(colors: [s.color.opacity(0.32), s.color.opacity(0.02)]),
                        startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                }
                context.stroke(line, with: .color(s.color),
                               style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round,
                                                  dash: s.dashed ? [4, 3] : []))
            }
        }
        .frame(height: height)
        // A Canvas is just pixels to VoiceOver, so describe it in words.
        .accessibilityElement()
        .accessibilityLabel("History chart")
        .accessibilityValue(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        series.compactMap { s -> String? in
            guard let last = s.points.last?.value else { return nil }
            let peak = s.points.map(\.value).max() ?? last
            return "latest \(gridLabel(last)), peak \(gridLabel(peak))"
        }.joined(separator: "; ")
    }

    private func drawGrid(in context: inout GraphicsContext, size: CGSize, top: Double) {
        for step in 0...4 {
            let fraction = Double(step) / 4
            let y = size.height * (1 - fraction)
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(line, with: .color(.secondary.opacity(step == 0 ? 0.35 : 0.15)), lineWidth: 0.5)
            if step > 0 {
                let label = Text(gridLabel(top * fraction)).font(.caption2).foregroundStyle(.secondary)
                context.draw(label, at: CGPoint(x: size.width - 2, y: y + 2), anchor: .topTrailing)
            }
        }
    }
}

/// Convenience: single filled series (CPU %, memory %…).
struct HistoryChart: View {
    let history: History
    let tint: Color
    var maxValue: Double = 100
    var showsAxes = false
    var height: CGFloat = 70

    var body: some View {
        SparklineChart(series: [ChartSeries(points: history.points, color: tint, filled: true)],
                       capacity: history.capacity, maxValue: maxValue, showsGrid: showsAxes,
                       gridLabel: { String(format: "%.0f%%", $0) }, height: height)
    }
}

/// Convenience: two series such as download vs upload, auto-scaled.
struct DualHistoryChart: View {
    let first: History
    let second: History
    let firstLabel: String
    let secondLabel: String
    let firstTint: Color
    let secondTint: Color
    var showsAxes = false
    var showsLegend = false
    var gridLabel: (Double) -> String = { String(format: "%.1f", $0) }
    var height: CGFloat = 70

    var body: some View {
        SparklineChart(series: [ChartSeries(points: first.points, color: firstTint, filled: true),
                                ChartSeries(points: second.points, color: secondTint)],
                       capacity: first.capacity, showsGrid: showsAxes, gridLabel: gridLabel, height: height)
            .overlay(alignment: .topLeading) {
                if showsLegend {
                    HStack(spacing: 12) {
                        legendDot(firstLabel, firstTint)
                        legendDot(secondLabel, secondTint)
                    }
                    .font(.caption)
                    .padding(6)
                }
            }
    }

    private func legendDot(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).foregroundStyle(.secondary)
        }
    }
}
