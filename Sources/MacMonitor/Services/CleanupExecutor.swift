import Foundation

/// Carries out an approved cleanup plan (Phase 10). This is the **only** code
/// in MacMonitor that moves or deletes files, and it only ever touches the
/// items in the plan the user confirmed.
///
/// For each approved item, one at a time:
///  1. Stop if the user pressed Stop (remaining items are left untouched).
///  2. Re-check it with every `CleanupValidator` rule *immediately* before
///     acting. Anything that changed or fails a rule is skipped.
///  3. Skip it if a running program has it (or anything inside it) open.
///  4. Normal items → **moved to the Trash** (`FileManager.trashItem`), so you
///     can put them back. Nothing is deleted outright.
///     Items already *in* the Trash → deleted permanently, but only if the
///     user ticked the separate "permanently deleted" confirmation.
///  5. Record exactly what happened, including clear errors.
///
/// What it never does: run `rm -rf`, use `sudo` or ask for admin rights,
/// follow symbolic links (moving a link moves the link itself, never its
/// target), or act on anything that isn't in the plan.
enum CleanupExecutor {
    typealias ProgressHandler = @Sendable (CleanupProgress) async -> Void

    @concurrent
    static func run(_ plan: CleanupPlan,
                    trashAcknowledged: Bool,
                    options: CleanerScanner.Options,
                    remover: some ItemRemover = SystemItemRemover(),
                    openFiles: @Sendable () -> OpenFilesSnapshot = { OpenFilesSnapshot.capture() },
                    progress: ProgressHandler) async -> CleanupOutcome {
        let roots = CleanerScanner.allowedRoots(options)
        let inUse = openFiles()
        var results: [ItemResult] = []
        var stopped = false

        for (index, item) in plan.items.enumerated() {
            // 1. Stop requested?
            if Task.isCancelled { stopped = true }
            if stopped {
                results.append(ItemResult(item: item, kind: .notAttempted))
                continue
            }
            await progress(CleanupProgress(done: index, total: plan.items.count, currentName: item.name))

            // Defence in depth: review-only categories are never acted on.
            guard item.category.isSelectable else {
                results.append(ItemResult(item: item, kind: .skipped(.rejected("Large personal files are review-only."))))
                continue
            }

            // 2. Re-check right before acting.
            let verdict = CleanupValidator.check(item, allowedRoots: roots, scanDate: plan.scanDate)
            guard verdict.isReady else {
                results.append(ItemResult(item: item, kind: .skipped(verdict)))
                continue
            }

            // 3. In use by a running program?
            let users = inUse.users(of: CleanupValidator.canonical(item.url))
            guard users.isEmpty else {
                results.append(ItemResult(item: item, kind: .inUse(users.prefix(3).joined(separator: ", "))))
                continue
            }

            // 4. Act.
            do {
                if item.category == .trash {
                    guard trashAcknowledged else {
                        results.append(ItemResult(item: item, kind: .skipped(.rejected(
                            "Permanent deletion wasn't confirmed, so this Trash item was left alone."))))
                        continue
                    }
                    try remover.deletePermanently(item.url)
                    results.append(ItemResult(item: item, kind: .deletedPermanently))
                } else {
                    try remover.moveToTrash(item.url)
                    results.append(ItemResult(item: item, kind: .movedToTrash))
                }
            } catch {
                results.append(ItemResult(item: item, kind: kind(for: error)))
            }
        }
        await progress(CleanupProgress(done: plan.items.count, total: plan.items.count, currentName: ""))
        return CleanupOutcome(plan: plan, results: results, wasStopped: stopped)
    }

    /// Turns a file-system error into a plain-English result.
    static func kind(for error: Error) -> ItemResultKind {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(nsError.code) {
            return .skipped(.missing)
        }
        let posix = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap {
            $0.domain == NSPOSIXErrorDomain ? Int32($0.code) : nil
        } ?? (nsError.domain == NSPOSIXErrorDomain ? Int32(nsError.code) : nil)
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteNoPermissionError
            || posix == EPERM || posix == EACCES {
            return .failed("macOS didn't allow MacMonitor to move this item. It may be protected; Full Disk Access might be needed.")
        }
        if posix == EBUSY {
            return .failed("The item is busy. Quit the app using it and try again.")
        }
        return .failed(nsError.localizedDescription)
    }
}

/// The two file operations cleanup uses, behind a protocol so tests can use a
/// fake Trash folder instead of your real one.
protocol ItemRemover: Sendable {
    func moveToTrash(_ url: URL) throws
    func deletePermanently(_ url: URL) throws
}

/// The real implementation.
struct SystemItemRemover: ItemRemover {
    func moveToTrash(_ url: URL) throws {
        // Same as Finder's "Move to Trash": the item keeps its name and can be
        // restored with "Put Back".
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    func deletePermanently(_ url: URL) throws {
        // Only used for items that are already in the Trash, after the user's
        // separate confirmation. Removes exactly this one item.
        try FileManager.default.removeItem(at: url)
    }
}
