import Foundation

/// Latest macOS for this Mac, and a security summary (Information page).
///
/// ## Sources (Apple only, HTTPS)
/// - **gdmf.apple.com/v2/pmv** – Apple's public software update feed (used by
///   Apple's device-management tools). Each macOS release lists the exact
///   board IDs it supports, so "compatible with this Mac" is a fact, not a guess.
/// - **support.apple.com/en-us/100100** – Apple Security Releases, plus the
///   linked page of each update, for CVE IDs and their "Impact" descriptions.
///
/// ## Privacy and network use
/// Both are public lists downloaded in full; the filtering for this Mac
/// happens locally, so nothing about this Mac (board ID, serial, version) is
/// sent. Results are cached for 12 hours in ~/Library/Caches; the network is
/// only used when the Information page opens with a stale cache, or on Refresh.
///
/// Bug fixes and known issues are not summarized: Apple doesn't publish them
/// in a reliable machine-readable form, so the page links to Software Update.
enum MacOSUpdateService {
    static let catalogURL = URL(string: "https://gdmf.apple.com/v2/pmv")!
    static let securityIndexURL = URL(string: "https://support.apple.com/en-us/100100")!
    static let cacheLifetime: TimeInterval = 12 * 3600

    enum FetchError: LocalizedError {
        case offline, badResponse(String)
        var errorDescription: String? {
            switch self {
            case .offline: "You appear to be offline."
            case .badResponse(let what): "Apple's \(what) couldn't be read right now."
            }
        }
    }

    // MARK: - Fetch (with cache)

    @concurrent
    static func fetch(boardID: String, installedVersion: String) async throws -> MacOSUpdateInfo {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }

        let catalog = try await download(catalogURL, session: session, what: "software update catalog")
        let (latestReleased, latestCompatible) = try parseCatalog(catalog, boardID: boardID)

        // Security pages are optional: if they fail, the version info still shows.
        var names: [String: String] = [:]
        var security: [SecurityRelease] = []
        if let index = try? await download(securityIndexURL, session: session, what: "security releases page") {
            let rows = parseSecurityIndex(String(decoding: index, as: UTF8.self))
            names = releaseNames(from: rows)
            let target = latestCompatible?.version ?? installedVersion
            for row in rows where isNewer(row.version, than: installedVersion) && !isNewer(row.version, than: target)
                && major(of: row.version) == major(of: target) {
                guard security.count < 3 else { break }
                var release = SecurityRelease(title: row.title, version: row.version, releaseDate: row.date, url: row.url,
                                              issueCount: 0, cveIDs: [], groups: [], exploitedInTheWild: false)
                if let link = row.url, let url = URL(string: link),
                   let page = try? await download(url, session: session, what: "security notes") {
                    release = summarizeSecurityPage(String(decoding: page, as: UTF8.self), base: release)
                }
                security.append(release)
            }
        }
        let info = MacOSUpdateInfo(latestReleased: latestReleased, latestCompatible: latestCompatible,
                                   releaseNames: names, securityReleases: security, fetchedAt: Date(),
                                   boardID: boardID, installedVersion: installedVersion)
        saveCache(info)
        return info
    }

    private static func download(_ url: URL, session: URLSession, what: String) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("MacMonitor", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw FetchError.badResponse(what) }
            return data
        } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
            throw FetchError.offline
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is FetchError {
            throw FetchError.badResponse(what)
        } catch {
            throw FetchError.badResponse(what)
        }
    }

    // MARK: - Cache

    static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "local.macmonitor.MacMonitor/macos-updates.json")
    }

    static func loadCache() -> MacOSUpdateInfo? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(MacOSUpdateInfo.self, from: data)
    }

    private static func saveCache(_ info: MacOSUpdateInfo) {
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(info).write(to: cacheURL, options: .atomic)
    }

    static func isFresh(_ info: MacOSUpdateInfo, boardID: String, installedVersion: String, now: Date = Date()) -> Bool {
        info.boardID == boardID && info.installedVersion == installedVersion
            && now.timeIntervalSince(info.fetchedAt) < cacheLifetime
    }

    // MARK: - Parsing (pure, unit-tested)

    /// Newest release overall, and newest release whose supported devices include `boardID`.
    static func parseCatalog(_ data: Data, boardID: String) throws -> (MacOSRelease?, MacOSRelease?) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sets = root["PublicAssetSets"] as? [String: Any],
              let entries = sets["macOS"] as? [[String: Any]] else {
            throw FetchError.badResponse("software update catalog")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        var latest: MacOSRelease?
        var compatible: MacOSRelease?
        for entry in entries {
            guard let version = entry["ProductVersion"] as? String else { continue }
            let release = MacOSRelease(version: version, build: entry["Build"] as? String ?? "",
                                       postingDate: (entry["PostingDate"] as? String).flatMap(formatter.date(from:)))
            if latest.map({ isNewer(version, than: $0.version) }) ?? true { latest = release }
            let devices = (entry["SupportedDevices"] as? [String] ?? []).map { $0.lowercased() }
            if devices.contains(boardID.lowercased()),
               compatible.map({ isNewer(version, than: $0.version) }) ?? true {
                compatible = release
            }
        }
        return (latest, compatible)
    }

    struct SecurityIndexRow: Equatable {
        var title: String
        var version: String
        var date: String
        var url: String?
    }

    /// macOS rows of Apple's Security Releases table, newest first.
    static func parseSecurityIndex(_ html: String) -> [SecurityIndexRow] {
        var rows: [SecurityIndexRow] = []
        let rowPattern = try! NSRegularExpression(pattern: "<tr>(.*?)</tr>", options: [.dotMatchesLineSeparators])
        let cellPattern = try! NSRegularExpression(pattern: "<td[^>]*>(.*?)</td>", options: [.dotMatchesLineSeparators])
        let ns = html as NSString
        for row in rowPattern.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let rowText = ns.substring(with: row.range(at: 1)) as NSString
            let cells = cellPattern.matches(in: rowText as String, range: NSRange(location: 0, length: rowText.length))
                .map { rowText.substring(with: $0.range(at: 1)) }
            guard cells.count >= 3 else { continue }
            let title = plainText(cells[0]).components(separatedBy: "This update").first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard title.hasPrefix("macOS"), let version = title.split(separator: " ").last.map(String.init),
                  version.first?.isNumber == true else { continue }
            let link = cells[0].range(of: #"href="([^"]+)""#, options: .regularExpression).map {
                String(cells[0][$0].dropFirst(6).dropLast())
            }.flatMap(trustedAppleLink)
            rows.append(SecurityIndexRow(title: title, version: version, date: plainText(cells[2]), url: link))
        }
        return rows
    }

    /// Links scraped from Apple's page are later downloaded and shown as
    /// buttons, so only HTTPS links to Apple's own sites are kept.
    static func trustedAppleLink(_ link: String) -> String? {
        guard let url = URL(string: link), url.scheme?.lowercased() == "https",
              let host = url.host()?.lowercased(),
              host == "apple.com" || host.hasSuffix(".apple.com") else { return nil }
        return url.absoluteString
    }

    /// "27" → "Golden Gate" from titles like "macOS Golden Gate 27.2".
    static func releaseNames(from rows: [SecurityIndexRow]) -> [String: String] {
        var names: [String: String] = [:]
        for row in rows {
            let words = row.title.split(separator: " ").dropFirst().dropLast()   // drop "macOS" and the version
            guard !words.isEmpty, let major = major(of: row.version) else { continue }
            names[String(major)] = names[String(major)] ?? words.joined(separator: " ")
        }
        return names
    }

    /// Groups a security page's issues by kind of impact.
    static func summarizeSecurityPage(_ html: String, base: SecurityRelease) -> SecurityRelease {
        var text = plainText(html.replacingOccurrences(of: "</p>", with: "\n").replacingOccurrences(of: "<br", with: "\n<br"))
        // Credits for researchers follow; they aren't fixes.
        if let cut = text.range(of: "Additional recognition") { text = String(text[..<cut.lowerBound]) }
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        var groups: [ImpactCategory: ImpactGroup] = [:]
        var allCVEs: [String] = []
        var issues = 0
        var exploited = false
        var current: (ImpactCategory, String)?
        for line in lines {
            if line.hasPrefix("Impact:") {
                let impact = String(line.dropFirst("Impact:".count)).trimmingCharacters(in: .whitespaces)
                current = (classify(impact), impact)
                issues += 1
                var group = groups[current!.0] ?? ImpactGroup(category: current!.0, count: 0, example: impact, cveIDs: [])
                group.count += 1
                groups[current!.0] = group
            }
            if line.localizedCaseInsensitiveContains("may have been exploited")
                || line.localizedCaseInsensitiveContains("actively exploited") {
                exploited = true
                if let previous = current, previous.0 != .exploited {
                    // Move this issue (and the CVEs that follow it) to "Actively exploited".
                    groups[previous.0]?.count -= 1
                    var group = groups[.exploited] ?? ImpactGroup(category: .exploited, count: 0, example: previous.1, cveIDs: [])
                    group.count += 1
                    groups[.exploited] = group
                    current = (.exploited, previous.1)
                }
            }
            for cve in line.matches(of: /CVE-\d{4}-\d{4,7}/).map({ String($0.output) }) where !allCVEs.contains(cve) {
                allCVEs.append(cve)
                if let current { groups[current.0]?.cveIDs.append(cve) }
            }
        }
        var release = base
        release.issueCount = issues
        release.cveIDs = allCVEs
        release.exploitedInTheWild = exploited
        release.groups = ImpactCategory.allCases.compactMap { groups[$0] }.filter { $0.count > 0 }
        return release
    }

    static func classify(_ impact: String) -> ImpactCategory {
        let text = impact.lowercased()
        if text.contains("kernel privileges") || text.contains("root privileges") || text.contains("elevate privileges")
            || text.contains("break out of its sandbox") || text.contains("sandbox escape") { return .privilegeEscalation }
        if text.contains("arbitrary code") || text.contains("code execution") { return .codeExecution }
        if text.contains("bypass") || text.contains("spoof") || text.contains("gatekeeper") { return .securityBypass }
        if text.contains("sensitive") || text.contains("privacy") || text.contains("user data") || text.contains("location")
            || text.contains("keychain") || text.contains("access") { return .privacy }
        if text.contains("termination") || text.contains("denial") || text.contains("crash") { return .crash }
        return .other
    }

    /// Spec classification, applied to the releases newer than what's installed.
    static func priority(for releases: [SecurityRelease], updateAvailable: Bool) -> UpdatePriority {
        guard updateAvailable else { return .low }
        if releases.contains(where: \.exploitedInTheWild) { return .critical }
        let kinds = Set(releases.flatMap { $0.groups.map(\.category) })
        if kinds.contains(.privilegeEscalation) && kinds.contains(.codeExecution) { return .critical }
        if !kinds.isDisjoint(with: [.codeExecution, .privilegeEscalation, .securityBypass]) { return .high }
        if releases.contains(where: { $0.issueCount > 0 }) { return .medium }
        return .low
    }

    /// One sentence explaining why `priority` chose its level.
    static func priorityReason(for releases: [SecurityRelease], updateAvailable: Bool) -> String {
        guard updateAvailable else { return "You're on the latest macOS available for this Mac." }
        if releases.contains(where: \.exploitedInTheWild) {
            return "Apple reports that an issue fixed by this update may have been actively exploited."
        }
        let kinds = Set(releases.flatMap { $0.groups.map(\.category) })
        if kinds.contains(.privilegeEscalation) && kinds.contains(.codeExecution) {
            return "The update fixes issues that could let an attacker run code and gain higher (root or kernel) privileges. None are reported as exploited."
        }
        if !kinds.isDisjoint(with: [.codeExecution, .privilegeEscalation, .securityBypass]) {
            return "The update fixes code-execution, privilege or security-bypass issues."
        }
        if releases.contains(where: { $0.issueCount > 0 }) { return "The update fixes lower-impact issues such as crashes or data access." }
        return "No security content is published for this update."
    }

    // MARK: - Versions

    /// "27.0.1" vs "27.2": compares numerically, part by part.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    static func major(of version: String) -> Int? { version.split(separator: ".").first.flatMap { Int($0) } }

    private static func plainText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "<[^>]+>", with: "\n", options: .regularExpression)
        for (entity, char) in [("&nbsp;", " "), ("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&#x27;", "'")] {
            text = text.replacingOccurrences(of: entity, with: char)
        }
        return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
