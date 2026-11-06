import Foundation

/// One sample in a history chart. `id` is a monotonically increasing sample
/// counter, which doubles as the chart's X value.
struct HistoryPoint: Identifiable, Sendable, Equatable {
    let id: Int
    let value: Double
}

/// A fixed-size rolling list of samples for one chart.
///
/// When a new sample arrives and the list is full, the oldest one is dropped,
/// so memory use stays constant no matter how long the app runs.
struct History: Sendable, Equatable {
    private(set) var points: [HistoryPoint] = []
    /// Maximum number of samples kept (= history seconds ÷ refresh interval).
    private(set) var capacity = 120
    private var nextID = 0

    mutating func append(_ value: Double, capacity: Int) {
        self.capacity = max(capacity, 2)
        points.append(HistoryPoint(id: nextID, value: value))
        nextID += 1
        let overflow = points.count - self.capacity
        if overflow > 0 { points.removeFirst(overflow) }
    }
}
