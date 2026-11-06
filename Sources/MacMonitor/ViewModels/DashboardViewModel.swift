import Foundation
import Observation

/// The metrics shown in the app. Used to track which ones are still mock data.
enum Metric: Sendable {
    case cpu, memory, storage, network, cleaner
}

/// Holds the latest metrics and their history for every screen.
///
/// - `@Observable` lets SwiftUI views re-render automatically when a property
///   they read changes – no manual "publish" calls needed.
/// - `@MainActor` means all of this class's code runs on the main thread,
///   which is where UI state must live. Swift 6 enforces this at compile time.
///
/// Every metric comes from a real service:
/// Phase 3 = CPU, Phase 4 = memory, Phase 5 = disk, Phase 6 = network (all done).
@MainActor
@Observable
final class DashboardViewModel {
    // MARK: Current values
    private(set) var cpu = CPUStats.zero
    private(set) var memory = MemoryStats.zero
    private(set) var disk = DiskStats.zero
    private(set) var network = NetworkStats.zero
    /// Memory per app; only refreshed while the Memory page is open.
    private(set) var appMemory = AppMemoryReport.empty
    /// nil until the first battery check finishes; see `hasBattery`.
    private(set) var battery: BatteryStats?
    /// false on Macs without a battery (desktops). nil = not checked yet.
    private(set) var hasBattery: Bool?
    /// Page shown in the window (sidebar selection, ⌘1–⌘8).
    var selectedPage: SidebarItem? = .overview

    /// Internet speed test (only ever started by the user).
    private(set) var speedTestState = SpeedTestState.idle
    private(set) var lastSpeedTest: SpeedTestResult? = DashboardViewModel.loadLastSpeedTest()
    /// CPU temperature (always "unavailable" – see CPUTemperatureService) and
    /// macOS's public thermal state.
    private(set) var cpuTemperature = CPUTemperatureService.read()
    private(set) var thermalState = CPUTemperatureService.thermalState()
    /// CPU used by MacMonitor itself (% of one core).
    private(set) var ownCPUUsage = 0.0

    // MARK: History (for charts)
    private(set) var cpuHistory = History()
    private(set) var cpuUserHistory = History()
    private(set) var memoryHistory = History()
    private(set) var downloadHistory = History()   // bytes/s
    private(set) var uploadHistory = History()     // bytes/s

    /// Metrics that still show simulated values. Empty since Phase 8 – every
    /// page now uses real data. Kept so a future feature can be previewed.
    let mockMetrics: Set<Metric> = []
    func isMock(_ metric: Metric) -> Bool { mockMetrics.contains(metric) }

    var processorName: String { cpuService.processorName }

    // MARK: Services
    @ObservationIgnored private var cpuService = CPUService()
    @ObservationIgnored private let memoryService = MemoryService()
    @ObservationIgnored private var networkService = NetworkService()

    init() {
        // Fill once so the first frame is not empty.
        memory = memoryService.sample() ?? .zero
    }

    // MARK: Refresh loop

    /// Runs until the calling task is canceled.
    ///
    /// Called from `.task {}` in ContentView, so SwiftUI cancels it
    /// automatically when the window closes.
    ///
    /// Design note: one shared 1-second clock instead of one loop per metric.
    /// Separate loops drift apart, so CPU and network would update at
    /// slightly different moments and the window would redraw twice per
    /// second. Measured: ~8% CPU with separate loops vs ~2–3% with one clock.
    /// Every interval in Settings is a whole number of seconds, so each metric
    /// simply refreshes on the ticks that are a multiple of its interval.
    func run() async {
        await refreshDisk()   // show real disk and battery figures right away
        await refreshBattery()
        var second = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { break }
            second += 1
            // Nothing on screen to update: skip sampling entirely (Phase 11).
            guard isWindowVisible else { continue }
            tick(second)
        }
    }

    // MARK: Window visibility (Phase 11)

    /// false while the window is minimized, hidden, on another Space or
    /// completely covered. Monitoring pauses then, so MacMonitor uses almost
    /// no CPU in the background. (A running speed test or cleanup continues.)
    @ObservationIgnored private(set) var isWindowVisible = true

    func setWindowVisible(_ visible: Bool) {
        guard visible != isWindowVisible else { return }
        isWindowVisible = visible
        if visible {
            // Catch up straight away instead of waiting for the next tick.
            // (The first CPU/network values average the time spent hidden.)
            tick(0)
            Task { await refreshDisk(); await refreshBattery() }
        }
    }

    private func tick(_ second: Int) {
        let cpuInterval = Self.interval(forKey: SettingsKey.cpuInterval, default: SettingsDefaults.cpuInterval)
        let memoryInterval = Self.interval(forKey: SettingsKey.memoryInterval, default: SettingsDefaults.memoryInterval)
        let networkInterval = Self.interval(forKey: SettingsKey.networkInterval, default: SettingsDefaults.networkInterval)
        let diskInterval = Self.interval(forKey: SettingsKey.diskInterval, default: SettingsDefaults.diskInterval)

        if Self.isDue(second, every: cpuInterval) {
            refreshCPU(interval: cpuInterval)
        }
        if Self.isDue(second, every: memoryInterval) {
            refreshMemory(interval: memoryInterval)
        }
        if Self.isDue(second, every: networkInterval) {
            network = networkService.sample()
            downloadHistory.append(network.downloadBytesPerSecond, capacity: capacity(for: networkInterval))
            uploadHistory.append(network.uploadBytesPerSecond, capacity: capacity(for: networkInterval))
        }
        if Self.isDue(second, every: diskInterval) {
            // Disk is queried on a background thread (see DiskService), so it
            // runs as its own small task instead of blocking this tick.
            Task { await refreshDisk() }
        }
        if Self.isDue(second, every: 10) {
            // Battery level changes slowly; every 10 seconds is plenty.
            Task { await refreshBattery() }
        }
    }

    private static func isDue(_ second: Int, every interval: Double) -> Bool {
        second % max(1, Int(interval.rounded())) == 0
    }

    // MARK: CPU (real data since Phase 3)

    private func refreshCPU(interval: Double) {
        guard let stats = cpuService.sample() else { return }
        cpu = stats
        let newThermal = CPUTemperatureService.thermalState()
        if newThermal != thermalState { thermalState = newThermal }
        let cap = capacity(for: interval)
        cpuHistory.append(stats.total, capacity: cap)
        cpuUserHistory.append(stats.user, capacity: cap)
        ownCPUUsage = cpuService.ownProcessUsage()
    }

    // MARK: Memory (real data since Phase 4)

    private func refreshMemory(interval: Double) {
        guard let stats = memoryService.sample() else { return }
        memory = stats
        memoryHistory.append(stats.utilization, capacity: capacity(for: interval))
    }

    // MARK: Disk (real data since Phase 5)

    @ObservationIgnored private var diskRefreshInFlight = false

    private func refreshDisk() async {
        // Never start a second query while one is still running.
        guard !diskRefreshInFlight else { return }
        diskRefreshInFlight = true
        defer { diskRefreshInFlight = false }

        guard let stats = await DiskService.sample() else { return }
        // Only assign when something changed, so the UI doesn't redraw for nothing.
        if stats != disk { disk = stats }
    }

    // MARK: Disk Space Analyzer (Storage page) – read-only, user-initiated

    enum AnalyzerState: Equatable {
        case idle
        case running(StorageAnalysisProgress)
        case failed(String)
        case cancelled
    }

    private(set) var analyzerState = AnalyzerState.idle
    private(set) var appAnalysis: StorageAnalysis?
    /// Results per folder, kept for this session so going back is instant.
    /// "Rescan" replaces an entry; nothing re-scans on its own.
    private(set) var folderAnalyses: [URL: StorageAnalysis] = [:]
    /// The folder currently shown in Folders mode.
    var analyzerFolder: URL?
    @ObservationIgnored private var analyzerTask: Task<Void, Never>?

    var isAnalyzing: Bool { analyzerTask != nil }

    func analyzeApplications() {
        runAnalysis { progress in
            try await StorageAnalyzerService.analyzeApplications(progress: progress)
        } store: { self.appAnalysis = $0 }
    }

    func analyzeFolder(_ folder: URL, forceRescan: Bool = false) {
        analyzerFolder = folder
        if !forceRescan, folderAnalyses[folder] != nil { return }   // cached
        runAnalysis { progress in
            try await StorageAnalyzerService.analyzeFolder(folder, progress: progress)
        } store: { self.folderAnalyses[folder] = $0 }
    }

    func cancelAnalysis() { analyzerTask?.cancel() }

    private func runAnalysis(_ work: @escaping @Sendable (@escaping StorageAnalyzerService.ProgressHandler) async throws -> StorageAnalysis,
                             store: @escaping @MainActor (StorageAnalysis) -> Void) {
        guard analyzerTask == nil else { return }
        analyzerState = .running(StorageAnalysisProgress(current: "", filesSeen: 0))
        analyzerTask = Task {
            do {
                let analysis = try await work { progress in
                    await self.updateAnalyzerProgress(progress)
                }
                store(analysis)
                analyzerState = .idle
            } catch is CancellationError {
                analyzerState = .cancelled
            } catch {
                analyzerState = .failed(error.localizedDescription)
            }
            analyzerTask = nil
        }
    }

    private func updateAnalyzerProgress(_ progress: StorageAnalysisProgress) {
        if let task = analyzerTask, !task.isCancelled { analyzerState = .running(progress) }
    }

    // MARK: Information page

    enum UpdateFetchState: Equatable {
        case idle
        case loading
        case failed(String)
    }

    private(set) var systemInfo: SystemInfo?
    /// Cached Apple update/security data (shown only if it matches this Mac and version).
    private(set) var updateInfo: MacOSUpdateInfo? = MacOSUpdateService.loadCache()
    private(set) var updateFetchState = UpdateFetchState.idle
    private(set) var informationRefreshedAt: Date?

    /// Called when the Information page opens (force = false) and by Refresh
    /// (force = true). Local facts are always re-read; Apple's online data
    /// only if the 12-hour cache is stale, or when forced.
    func refreshInformation(force: Bool) async {
        let info = SystemInfoService.collect()
        systemInfo = info
        informationRefreshedAt = Date()
        guard let board = info.boardID else { return }
        if !force, let cached = updateInfo, MacOSUpdateService.isFresh(cached, boardID: board, installedVersion: info.osVersion) {
            return
        }
        guard updateFetchState != .loading else { return }
        updateFetchState = .loading
        do {
            updateInfo = try await MacOSUpdateService.fetch(boardID: board, installedVersion: info.osVersion)
            updateFetchState = .idle
        } catch is CancellationError {
            updateFetchState = .idle
        } catch {
            updateFetchState = .failed(error.localizedDescription)   // cached data (if any) stays visible
        }
    }

    // MARK: Flush DNS (Network page) – only after the user confirms

    enum DNSFlushState: Equatable {
        case idle
        case running
        case finished(DNSFlushService.Outcome, Date)
    }

    private(set) var dnsFlushState = DNSFlushState.idle

    /// Called only from the confirmation dialog's "Flush" button.
    func flushDNS() async {
        guard dnsFlushState != .running else { return }
        dnsFlushState = .running
        let outcome = await DNSFlushService.flush()
        dnsFlushState = .finished(outcome, Date())
    }

    // MARK: Connection details (Network page)

    enum PublicIPState: Equatable {
        case notLoaded
        case loading
        case loaded(String, Date)
        case failed(String)
    }

    let wifi = WiFiMonitor()
    private(set) var localAddresses: [NetworkInfoService.InterfaceAddress] = []
    private(set) var publicIP = PublicIPState.notLoaded
    @ObservationIgnored private var publicIPFetchedAt: Date?

    /// While the Network page is open: refresh Wi-Fi name and local addresses
    /// every 5 s (cheap, no network traffic). The public IP is looked up at
    /// most once every 15 minutes automatically, or when you press Refresh.
    func monitorConnectionInfo() async {
        if publicIPFetchedAt.map({ Date().timeIntervalSince($0) > 15 * 60 }) ?? true {
            Task { await refreshPublicIP() }
        }
        while !Task.isCancelled {
            if isWindowVisible {
                wifi.refresh()
                localAddresses = NetworkInfoService.ipv4Addresses()
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    func refreshPublicIP() async {
        guard publicIP != .loading else { return }
        publicIP = .loading
        do {
            let ip = try await NetworkInfoService.fetchPublicIPv4()
            publicIP = .loaded(ip, Date())
        } catch is CancellationError {
            publicIP = .notLoaded
        } catch {
            publicIP = .failed(error.localizedDescription)
        }
        publicIPFetchedAt = Date()   // also after failures, so it doesn't retry in a loop
    }

    // MARK: Process Monitor

    /// Latest process list (nil until the first scan finishes).
    private(set) var processSnapshot: ProcessSnapshot?
    /// Sort order shared by the Overview card and the Processes page.
    var processSort: ProcessSortKey = .cpu
    @ObservationIgnored private let processMonitor = ProcessMonitorService()
    @ObservationIgnored private var processLoopToken = 0

    /// Refreshes the process list every 3 seconds until canceled.
    ///
    /// Started by the `.task {}` of the Overview's process card and of the
    /// Processes page, so it only runs while one of them is on screen. If a
    /// new page starts a loop before the old one is canceled, only the
    /// newest keeps running (the token check), so processes are never
    /// sampled twice per interval.
    func monitorProcesses() async {
        processLoopToken += 1
        let token = processLoopToken
        while !Task.isCancelled, token == processLoopToken {
            if isWindowVisible {
                let snapshot = await processMonitor.sample()
                guard !Task.isCancelled, token == processLoopToken else { break }
                processSnapshot = snapshot
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    /// Immediate refresh, e.g. right after ending a process.
    func refreshProcessesNow() async {
        processSnapshot = await processMonitor.sample()
    }

    func topProcesses(_ count: Int) -> [ProcessEntry] {
        guard let entries = processSnapshot?.entries else { return [] }
        let sorted = processSort == .cpu
            ? entries.sorted { ($0.cpuPercent ?? 0, $0.memoryBytes) > ($1.cpuPercent ?? 0, $1.memoryBytes) }
            : entries.sorted { $0.memoryBytes > $1.memoryBytes }
        return Array(sorted.prefix(count))
    }

    func process(withPID pid: pid_t) -> ProcessEntry? {
        processSnapshot?.entries.first { $0.pid == pid }
    }

    // MARK: Memory by app

    /// Refreshes `appMemory` every 5 seconds until the caller is canceled.
    ///
    /// Called from the Memory page's `.task {}`. SwiftUI cancels it when you
    /// leave the page, so the process scan never runs in the background.
    func monitorAppMemory() async {
        while !Task.isCancelled {
            // Same background rule as the main loop: no scan while hidden.
            guard isWindowVisible else {
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            let report = await ProcessMemoryService.sample()
            if Task.isCancelled { break }
            if report != appMemory { appMemory = report }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    // MARK: Battery

    @ObservationIgnored private var batteryRefreshInFlight = false

    private func refreshBattery() async {
        guard !batteryRefreshInFlight, hasBattery != false else { return }
        batteryRefreshInFlight = true
        defer { batteryRefreshInFlight = false }

        switch await BatteryService.sample() {
        case .present(let stats):
            hasBattery = true
            if stats != battery { battery = stats }
        case .notInstalled:
            hasBattery = false   // desktop Mac: stop checking
            battery = nil
        case .unavailable:
            break                // keep the last good reading; try again later
        }
    }

    // MARK: Speed test (Phase 7) – runs only when the user asks

    @ObservationIgnored private var speedTestTask: Task<Void, Never>?

    var isSpeedTestRunning: Bool { speedTestTask != nil }

    func startSpeedTest() {
        guard speedTestTask == nil else { return }   // never two at once
        speedTestState = .running(SpeedTestProgress(phase: .connecting, fraction: 0))
        speedTestTask = Task {
            do {
                let result = try await SpeedTestService.run { progress in
                    await self.updateSpeedTestProgress(progress)
                }
                lastSpeedTest = result
                Self.saveLastSpeedTest(result)
                speedTestState = .idle
            } catch is CancellationError {
                speedTestState = .cancelled
            } catch {
                speedTestState = .failed(error.localizedDescription)
            }
            speedTestTask = nil
        }
    }

    func cancelSpeedTest() {
        speedTestTask?.cancel()
    }

    private func updateSpeedTestProgress(_ progress: SpeedTestProgress) {
        // Ignore late updates that arrive after Cancel was pressed.
        guard speedTestTask != nil, !(speedTestTask?.isCancelled ?? true) else { return }
        speedTestState = .running(progress)
    }

    /// The last result is kept in UserDefaults so it survives restarts.
    private static let lastSpeedTestKey = "lastSpeedTest"

    private static func loadLastSpeedTest() -> SpeedTestResult? {
        UserDefaults.standard.data(forKey: lastSpeedTestKey)
            .flatMap { try? JSONDecoder().decode(SpeedTestResult.self, from: $0) }
    }

    private static func saveLastSpeedTest(_ result: SpeedTestResult) {
        if let data = try? JSONEncoder().encode(result) {
            UserDefaults.standard.set(data, forKey: lastSpeedTestKey)
        }
    }

    // MARK: Storage Cleaner scan (Phase 8) – read-only, only when the user asks

    enum ScanState: Equatable {
        case idle
        case scanning(ScanProgress)
        case failed(String)
        case cancelled
    }

    private(set) var scanState = ScanState.idle
    private(set) var scanReport: ScanReport?
    /// Category open in the Cleaner's review list (nil = dashboard).
    var cleanerOpenCategory: CleanupCategory?
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    var isScanning: Bool { scanTask != nil }

    func startScan(includeLargeFiles: Bool) {
        guard scanTask == nil, cleanupTask == nil else { return }
        scanState = .scanning(ScanProgress(category: .appCaches, step: 0, totalSteps: CleanupCategory.allCases.count, filesSeen: 0))
        var options = CleanerScanner.Options()
        options.includeLargeFiles = includeLargeFiles
        lastScanOptions = options
        // A new scan replaces the old findings, so any old selection or
        // pending confirmation no longer applies.
        cleanerSelection = []
        cleanupPlan = nil
        cleanupOutcome = nil
        scanTask = Task {
            do {
                let report = try await CleanerScanner.scan(options: options) { progress in
                    await self.updateScanProgress(progress)
                }
                scanReport = report
                scanState = .idle
            } catch is CancellationError {
                scanState = .cancelled
            } catch {
                scanState = .failed(error.localizedDescription)
            }
            scanTask = nil
        }
    }

    func cancelScan() { scanTask?.cancel() }

    private func updateScanProgress(_ progress: ScanProgress) {
        guard let task = scanTask, !task.isCancelled else { return }
        scanState = .scanning(progress)
    }

    // MARK: Cleanup selection and approval (Phase 9)

    /// Paths of the items the user ticked. Nothing is ever pre-selected.
    var cleanerSelection: Set<String> = []
    /// The frozen list shown on the confirmation screen (nil = not open).
    var cleanupPlan: CleanupPlan?
    /// Result of the last confirmed plan.
    var cleanupOutcome: CleanupOutcome?
    /// Set while a confirmed plan is being carried out.
    private(set) var cleanupProgress: CleanupProgress?
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?
    @ObservationIgnored private var lastScanOptions = CleanerScanner.Options()

    func isSelected(_ item: CleanupItem) -> Bool { cleanerSelection.contains(item.id) }

    func setSelected(_ item: CleanupItem, _ selected: Bool) {
        guard item.category.isSelectable else { return }
        if selected { cleanerSelection.insert(item.id) } else { cleanerSelection.remove(item.id) }
    }

    func select(_ items: [CleanupItem]) {
        cleanerSelection.formUnion(items.filter(\.category.isSelectable).map(\.id))
    }

    /// Tick state of a whole category in the Breakdown list.
    enum CategorySelection { case none, some, all }

    func selectionState(of report: CategoryReport) -> CategorySelection {
        let eligible = report.items.filter(\.category.isSelectable)
        let ticked = eligible.filter { cleanerSelection.contains($0.id) }.count
        if eligible.isEmpty || ticked == 0 { return .none }
        return ticked == eligible.count ? .all : .some
    }

    /// Category checkbox: all ticked → untick all; otherwise tick all eligible.
    func toggleCategory(_ report: CategoryReport) {
        if selectionState(of: report) == .all { deselect(report.items) } else { select(report.items) }
    }

    func selectedSize(in report: CategoryReport) -> UInt64 {
        report.items.filter { cleanerSelection.contains($0.id) }.reduce(0) { $0 + $1.size }
    }
    func deselect(_ items: [CleanupItem]) { cleanerSelection.subtract(items.map(\.id)) }
    func clearSelection() { cleanerSelection = [] }

    /// Selected items, taken only from the current scan report.
    var selectedItems: [CleanupItem] {
        guard let report = scanReport, !cleanerSelection.isEmpty else { return [] }
        return report.categories.flatMap(\.items).filter { cleanerSelection.contains($0.id) }
    }

    /// Step 5: freeze the selection into a plan and show the confirmation screen.
    func reviewCleanup() {
        guard let report = scanReport, !selectedItems.isEmpty else { return }
        cleanupPlan = CleanupPlan(items: selectedItems, scanDate: report.date)
    }

    var isCleaning: Bool { cleanupTask != nil }

    /// Step 6 → 7 → 8. Only ever called from the confirmation screen's
    /// "Confirm Cleanup" button, with that exact plan.
    func confirmCleanup(_ plan: CleanupPlan, trashAcknowledged: Bool) {
        guard cleanupPlan?.id == plan.id, cleanupTask == nil else { return }   // only the plan on screen, once
        cleanupProgress = CleanupProgress(done: 0, total: plan.items.count, currentName: "")
        let options = lastScanOptions
        cleanupTask = Task {
            let outcome = await CleanupExecutor.run(plan, trashAcknowledged: trashAcknowledged, options: options) { progress in
                await self.updateCleanupProgress(progress)
            }
            finishCleanup(outcome)
        }
    }

    /// Stops after the item currently being moved. Items not reached are left alone.
    func stopCleanup() { cleanupTask?.cancel() }

    /// Waits for a running cleanup (used by the developer self-test).
    func waitForCleanup() async { await cleanupTask?.value }

    private func updateCleanupProgress(_ progress: CleanupProgress) {
        if cleanupTask != nil { cleanupProgress = progress }
    }

    private func finishCleanup(_ outcome: CleanupOutcome) {
        cleanupTask = nil
        cleanupProgress = nil
        cleanupOutcome = outcome   // the open confirmation sheet now shows the results
        // Remove cleaned items from the report and the selection.
        let cleanedPaths = Set(outcome.cleaned.map(\.item.id))
        cleanerSelection.subtract(cleanedPaths)
        scanReport = scanReport?.removing(cleanedPaths)
        Task { await refreshDisk() }   // free space changed
    }

    // MARK: Helpers

    /// Number of samples that fit in the chart history window.
    private func capacity(for interval: Double) -> Int {
        let stored = UserDefaults.standard.integer(forKey: SettingsKey.historySeconds)
        let seconds = stored > 0 ? stored : SettingsDefaults.historySeconds
        return max(10, Int(Double(seconds) / interval))
    }

    private static func interval(forKey key: String, default defaultValue: Double) -> Double {
        let stored = UserDefaults.standard.double(forKey: key)
        return stored > 0 ? stored : defaultValue
    }

    /// Length of the chart window in seconds, for labels.
    var historySeconds: Int {
        let stored = UserDefaults.standard.integer(forKey: SettingsKey.historySeconds)
        return stored > 0 ? stored : SettingsDefaults.historySeconds
    }

}
