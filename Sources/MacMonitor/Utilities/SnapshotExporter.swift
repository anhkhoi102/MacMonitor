import AppKit

/// Developer tool: saves a PNG of every page, then quits.
///
/// Enabled only when the MACMONITOR_SNAPSHOT_DIR environment variable is set
/// (see Scripts/snapshot.sh). The window draws itself into an image with
/// `cacheDisplay`, so no Screen Recording permission is needed.
/// In normal use this does nothing.
@MainActor
enum SnapshotExporter {
    static func runIfRequested(select: (SidebarItem) -> Void) async {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["MACMONITOR_SNAPSHOT_DIR"] else { return }

        let suffix: String
        switch env["MACMONITOR_SNAPSHOT_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua); suffix = "-dark"
        case "light": NSApp.appearance = NSAppearance(named: .aqua); suffix = "-light"
        default: suffix = ""
        }

        // Optional taller window so long pages fit (MACMONITOR_SNAPSHOT_HEIGHT=1600).
        if let height = env["MACMONITOR_SNAPSHOT_HEIGHT"].flatMap(Double.init),
           let window = NSApp.windows.first(where: { $0.isVisible }) {
            window.setFrame(NSRect(x: 0, y: 0, width: window.frame.width, height: height), display: true)
        }

        // Let a few samples accumulate so charts have data.
        try? await Task.sleep(for: .seconds(4))

        // Optional: MACMONITOR_SNAPSHOT_PAGES=processes,cpu captures only those pages.
        let only = env["MACMONITOR_SNAPSHOT_PAGES"].map { Set($0.split(separator: ",").map(String.init)) }
        for item in SidebarItem.allCases where only?.contains(item.rawValue) ?? true {
            select(item)
            try? await Task.sleep(for: .seconds(1.2))
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                  let view = window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(item.rawValue)\(suffix).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            // Second capture from the composited layer tree: correct for
            // pages with a scroll view inside the page (e.g. Processes),
            // which `cacheDisplay` draws at the wrong offset.
            if let layerImage = layerSnapshot(of: view) {
                let layerURL = URL(fileURLWithPath: dir).appendingPathComponent("\(item.rawValue)\(suffix)-layer.png")
                try? layerImage.write(to: layerURL)
            }

            // Pages taller than the window: also save the whole scrollable content.
            if let document = largestScrollDocument(in: view), document.bounds.height > view.bounds.height,
               let fullRep = document.bitmapImageRepForCachingDisplay(in: document.bounds) {
                document.cacheDisplay(in: document.bounds, to: fullRep)
                let fullURL = URL(fileURLWithPath: dir).appendingPathComponent("\(item.rawValue)\(suffix)-full.png")
                try? fullRep.representation(using: .png, properties: [:])?.write(to: fullURL)
            }
        }
        NSApp.terminate(nil)
    }

    /// Developer check: MACMONITOR_DEV_SPEEDTEST=<folder> runs one speed test,
    /// logs every progress step, saves a screenshot of the result, then quits.
    /// Nothing happens unless that variable is set.
    static func runSpeedTestIfRequested(vm: DashboardViewModel, select: (SidebarItem) -> Void) async {
        guard let dir = ProcessInfo.processInfo.environment["MACMONITOR_DEV_SPEEDTEST"] else { return }
        select(.network)
        try? await Task.sleep(for: .seconds(1))
        var log = ""
        let start = ContinuousClock.now
        vm.startSpeedTest()
        while vm.isSpeedTestRunning {
            if case .running(let p) = vm.speedTestState {
                log += String(format: "%6.1fs  %-18@ %3.0f%%  %@\n", (ContinuousClock.now - start) / .seconds(1),
                              p.phase.rawValue, p.fraction * 100, p.currentMbps.map { String(format: "%.1f Mbps", $0) } ?? "")
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        log += "state: \(vm.speedTestState)\n"
        if let result = vm.lastSpeedTest, let json = try? JSONEncoder().encode(result) {
            log += String(decoding: json, as: UTF8.self) + "\n"
        }
        try? log.write(toFile: dir + "/speedtest-log.txt", atomically: true, encoding: .utf8)
        try? await Task.sleep(for: .seconds(1))
        if let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
           let document = largestScrollDocument(in: view),
           let rep = document.bitmapImageRepForCachingDisplay(in: document.bounds) {
            document.cacheDisplay(in: document.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/speedtest.png"))
        }
        NSApp.terminate(nil)
    }

    /// Developer check: MACMONITOR_DEV_SCAN=<folder> runs one read-only cleaner
    /// scan, writes a text summary and a screenshot, then quits.
    static func runScanIfRequested(vm: DashboardViewModel, select: (SidebarItem) -> Void) async {
        guard let dir = ProcessInfo.processInfo.environment["MACMONITOR_DEV_SCAN"] else { return }
        select(.cleaner)
        try? await Task.sleep(for: .seconds(1))
        vm.startScan(includeLargeFiles: false)
        while vm.isScanning { try? await Task.sleep(for: .milliseconds(200)) }
        var text = "state: \(vm.scanState)\n"
        if let report = vm.scanReport {
            text += "took \(report.duration), recoverable \(report.recoverableSize) bytes, files \(report.fileCount)\n"
            for c in report.categories {
                text += "\(c.category.title): \(c.size) bytes, \(c.items.count) items, status \(c.status), notes \(c.notes)\n"
                for item in c.items.prefix(4) {
                    text += "    \(item.size)\t\(item.risk.title)\t\(item.path)\n"
                }
            }
        }
        // Show the category checkboxes: one whole category, one partly.
        if let report = vm.scanReport {
            if let logs = report.report(for: .appLogs) { vm.toggleCategory(logs) }
            if let first = report.report(for: .appCaches)?.items.first { vm.setSelected(first, true) }
        }
        try? text.write(toFile: dir + "/scan.txt", atomically: true, encoding: .utf8)
        try? await Task.sleep(for: .seconds(1))
        if let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
           let document = largestScrollDocument(in: view),
           let rep = document.bitmapImageRepForCachingDisplay(in: document.bounds) {
            document.cacheDisplay(in: document.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/cleaner.png"))
        }
        // Also capture one category's review list.
        vm.cleanerOpenCategory = .appCaches
        try? await Task.sleep(for: .seconds(1))
        if let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/category.png"))
        }
        NSApp.terminate(nil)
    }

    /// Name prefix of the throwaway folders the self-test may clean.
    /// Hard-coded on purpose: the self-test can never select anything else.
    static let selfTestPrefix = "MacMonitorSelfTest-"

    /// Developer self-test: MACMONITOR_DEV_CLEANUP=<folder> runs the full
    /// approval workflow for real – scan → select → confirm → move to Trash →
    /// results – but ONLY on items named "MacMonitorSelfTest-…" (folders the
    /// developer created for the test). If none exist it does nothing.
    static func runCleanupSelfTestIfRequested(vm: DashboardViewModel, select: (SidebarItem) -> Void) async {
        guard let dir = ProcessInfo.processInfo.environment["MACMONITOR_DEV_CLEANUP"] else { return }
        select(.cleaner)
        try? await Task.sleep(for: .seconds(1))
        vm.startScan(includeLargeFiles: false)
        while vm.isScanning { try? await Task.sleep(for: .milliseconds(200)) }

        let picked = (vm.scanReport?.categories.flatMap(\.items) ?? []).filter { $0.name.hasPrefix(selfTestPrefix) }
        var log = "self-test items found: \(picked.map(\.name))\n"
        guard !picked.isEmpty else {
            try? (log + "nothing to do\n").write(toFile: dir + "/cleanup-log.txt", atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
            return
        }
        vm.select(picked)
        log += "selected in app: \(vm.selectedItems.map(\.name))\n"

        vm.reviewCleanup()
        try? await Task.sleep(for: .seconds(1.5))
        capture(sheetOf: dir + "/confirm.png")
        if let plan = vm.cleanupPlan {
            log += "plan: \(plan.items.map(\.path))\n"
            vm.confirmCleanup(plan, trashAcknowledged: false)
            await vm.waitForCleanup()
        }
        try? await Task.sleep(for: .seconds(1.5))
        capture(sheetOf: dir + "/result.png")

        if let outcome = vm.cleanupOutcome {
            log += "freed \(outcome.freedSize) bytes, moved \(outcome.movedCount), stopped \(outcome.wasStopped)\n"
            for result in outcome.results {
                log += "  \(result.kind.title): \(result.item.name) \(result.kind.detail ?? "")\n"
            }
        }
        for item in picked {
            var info = Darwin.stat()
            log += "after: \(item.name) \(lstat(item.path, &info) == 0 ? "still in place" : "no longer in Caches")\n"
        }
        try? log.write(toFile: dir + "/cleanup-log.txt", atomically: true, encoding: .utf8)
        // macOS won't quit while a sheet is open, so close the results first.
        vm.cleanupOutcome = nil
        vm.cleanupPlan = nil
        try? await Task.sleep(for: .seconds(0.5))
        NSApp.terminate(nil)
    }

    private static func capture(sheetOf path: String) {
        guard let sheet = NSApp.windows.first(where: { $0.isVisible })?.attachedSheet,
              let view = sheet.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Renders the view's Core Animation layer tree into a PNG.
    private static func layerSnapshot(of view: NSView) -> Data? {
        guard let layer = view.layer else { return nil }
        let scale = view.window?.backingScaleFactor ?? 2
        let width = Int(view.bounds.width * scale), height = Int(view.bounds.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// Developer check: MACMONITOR_DEV_ANALYZE=<folder> runs the app analysis
    /// and analyzes ~/workspace (read-only), writes a summary and a screenshot.
    static func runAnalyzerIfRequested(vm: DashboardViewModel, select: (SidebarItem) -> Void) async {
        guard let dir = ProcessInfo.processInfo.environment["MACMONITOR_DEV_ANALYZE"] else { return }
        select(.storage)
        try? await Task.sleep(for: .seconds(1))
        var text = ""
        vm.analyzeApplications()
        while vm.isAnalyzing { try? await Task.sleep(for: .milliseconds(200)) }
        if let apps = vm.appAnalysis {
            text += "apps: \(apps.entries.count) in \(apps.duration)\n"
            for e in apps.entries.prefix(8) {
                text += "  \(e.name)\tapp \(e.size)\tdata \(e.userDataSize ?? 0)\tlastOpened \(e.lastOpened.map { "\($0)" } ?? "Unknown")\n"
            }
            text += "  apps with Unknown last-opened: \(apps.entries.filter { $0.lastOpened == nil }.map(\.name))\n"
        }
        let workspace = FileManager.default.homeDirectoryForCurrentUser.appending(path: "workspace")
        vm.analyzeFolder(workspace)
        while vm.isAnalyzing { try? await Task.sleep(for: .milliseconds(200)) }
        if let folder = vm.folderAnalyses[workspace] {
            text += "workspace: \(folder.entries.count) items, \(folder.totalSize) bytes in \(folder.duration)\n"
            for e in folder.entries.prefix(5) { text += "  \(e.name)\t\(e.kind.rawValue)\t\(e.totalSize)\n" }
        }
        try? text.write(toFile: dir + "/analyze.txt", atomically: true, encoding: .utf8)
        // Scroll the page to the bottom (where the analyzer is) and capture
        // the window as seen, so the table draws its on-screen rows.
        vm.analyzerFolder = nil
        try? await Task.sleep(for: .seconds(1))
        if let window = NSApp.windows.first(where: { $0.isVisible }), let view = window.contentView,
           let document = largestScrollDocument(in: view) {
            document.scroll(NSPoint(x: 0, y: document.isFlipped ? document.bounds.maxY : 0))
            try? await Task.sleep(for: .seconds(1))
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/storage-scrolled.png"))
            }
        }
        if let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
           let document = largestScrollDocument(in: view),
           let rep = document.bitmapImageRepForCachingDisplay(in: document.bounds) {
            document.cacheDisplay(in: document.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/storage.png"))
        }
        NSApp.terminate(nil)
    }

    /// Developer check: MACMONITOR_DEV_INFO=<folder> loads the Information page
    /// with live data (serial number masked in the summary), screenshots it and
    /// the Power page (no power action is performed), then quits.
    static func runInformationIfRequested(vm: DashboardViewModel, select: (SidebarItem) -> Void) async {
        guard let dir = ProcessInfo.processInfo.environment["MACMONITOR_DEV_INFO"] else { return }
        select(.information)
        await vm.refreshInformation(force: true)
        var text = "fetch state: \(vm.updateFetchState)\n"
        if let i = vm.systemInfo {
            text += "macOS \(i.osVersion) (\(i.osBuild)) \(i.kernelVersion)\nmodel \(i.modelName ?? "nil") / \(i.modelIdentifier) board \(i.boardID ?? "nil")\n"
            text += "chip \(i.chip) \(i.coreDescription) mem \(i.memoryBytes) gpu \(i.gpuName ?? "nil") \(i.gpuCores ?? 0) arch \(i.architecture)\n"
            text += "serial present: \(i.serialNumber != nil) (masked)\n"
        }
        if let u = vm.updateInfo {
            text += "latest released \(u.latestReleased?.version ?? "nil") compatible \(u.latestCompatible?.version ?? "nil") \(u.latestCompatible?.postingDate.map { "\($0)" } ?? "")\n"
            text += "names \(u.releaseNames.sorted { $0.key > $1.key }.prefix(4))\n"
            for r in u.securityReleases {
                text += "security \(r.title): issues \(r.issueCount) cves \(r.cveIDs.count) exploited \(r.exploitedInTheWild) groups \(r.groups.map { "\($0.category.rawValue)=\($0.count)" })\n"
            }
            let available = u.latestCompatible.map { MacOSUpdateService.isNewer($0.version, than: vm.systemInfo?.osVersion ?? "") } ?? false
            text += "priority \(MacOSUpdateService.priority(for: u.securityReleases, updateAvailable: available).rawValue)\n"
        }
        try? text.write(toFile: dir + "/info.txt", atomically: true, encoding: .utf8)
        try? await Task.sleep(for: .seconds(1.5))
        for (page, file) in [(SidebarItem.information, "information"), (.power, "power")] {
            select(page)
            try? await Task.sleep(for: .seconds(1.2))
            if let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
               let document = largestScrollDocument(in: view),
               let rep = document.bitmapImageRepForCachingDisplay(in: document.bounds) {
                document.cacheDisplay(in: document.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/\(file).png"))
            }
        }
        NSApp.terminate(nil)
    }

    /// The content view of the tallest scroll view on screen (the page body).
    private static func largestScrollDocument(in view: NSView) -> NSView? {
        var best: NSView?
        func visit(_ v: NSView) {
            if let scroll = v as? NSScrollView, let doc = scroll.documentView,
               doc.bounds.height > (best?.bounds.height ?? 0) {
                best = doc
            }
            v.subviews.forEach(visit)
        }
        visit(view)
        return best
    }
}
