import Foundation

/// Reads the capacity of the startup volume (Phase 5).
///
/// ## Where the numbers come from
/// `URL.resourceValues(forKeys:)` asks the file system about the volume that
/// contains a path. We use "/" (the startup disk). On modern macOS that is a
/// read-only system volume sharing one APFS *container* with your data volume,
/// so the total and free space reported are those of the whole container –
/// the same figures Finder and `diskutil info /` show.
///
/// Two different "available" numbers exist:
///   - `volumeAvailableCapacityKey`: bytes free right now (= `df`).
///   - `volumeAvailableCapacityForImportantUsageKey`: free + purgeable space
///     macOS would clear for you (caches, local Time Machine snapshots).
///     This is what Finder calls "Available", so we use it as the main figure.
///
/// This is read-only: it never creates, changes or deletes files.
///
/// ## Why it runs off the main thread
/// Measured on an M1, this query takes 14–44 ms. The screen redraws every
/// 8–16 ms, so doing it on the main thread could cause a visible stutter.
/// `@concurrent` tells Swift to run the function on a background thread; the
/// caller `await`s the result and then updates the UI on the main actor.
enum DiskService {
    @concurrent
    static func sample(path: String = "/") async -> DiskStats? {
        let keys: Set<URLResourceKey> = [
            .volumeLocalizedNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys) else {
            return nil
        }
        return makeStats(name: values.volumeLocalizedName,
                         total: values.volumeTotalCapacity,
                         free: values.volumeAvailableCapacity,
                         importantAvailable: values.volumeAvailableCapacityForImportantUsage)
    }

    // MARK: - Pure calculation (unit-tested)

    /// Combines the raw values, tolerating missing or inconsistent ones.
    static func makeStats(name: String?, total: Int?, free: Int?, importantAvailable: Int64?) -> DiskStats? {
        guard let total, total > 0 else { return nil }
        let totalBytes = UInt64(total)
        let freeBytes = min(UInt64(max(free ?? 0, 0)), totalBytes)

        // Prefer Finder's figure; fall back to plain free space if it's
        // missing or nonsensical (smaller than free, or larger than the disk).
        var available = freeBytes
        if let importantAvailable, importantAvailable > 0 {
            let important = UInt64(importantAvailable)
            if important >= freeBytes && important <= totalBytes { available = important }
        }

        return DiskStats(volumeName: name ?? "Startup Disk",
                         total: totalBytes, available: available, free: freeBytes)
    }
}
