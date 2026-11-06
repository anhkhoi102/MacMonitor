import Darwin
import Foundation
import SystemConfiguration

/// Measures real network traffic (Phase 6). It never sends or receives
/// anything itself – it only reads counters the kernel already keeps.
///
/// ## How speed is measured
/// For every network interface the kernel counts the total bytes received and
/// sent since the Mac started. We read those counters once per interval:
///
///     download speed = (bytes received now − bytes received last time) ÷ seconds elapsed
///
/// We read them with `sysctl(NET_RT_IFLIST2)` (`netstat -ib` shows the same).
///
/// ## A macOS privacy limit we must handle
/// Apple's own tools get exact 64-bit counters. Ordinary apps like MacMonitor
/// get them **cut to 32 bits** (they wrap back to 0 every 4 GB) and **rounded
/// to 1 KB**. In testing, netstat's total minus a whole number of 4 GB wraps
/// equaled exactly what MacMonitor was given. Consequences:
///   - Speeds and session totals are still correct, because they only use the
///     difference between readings a second apart – `delta` recognizes a wrap
///     (e.g. 4.29 GB → 0.01 GB) as +20 MB of traffic.
///   - "Total since the Mac started" cannot be known, so we don't show it.
///   - Speeds have 1 KB/s resolution.
///
/// ## Which interfaces count
/// Only physical network hardware: interfaces named `en…` (Wi-Fi, Ethernet,
/// USB/Thunderbolt adapters). We skip `lo0` (traffic inside the Mac),
/// `awdl0`/`llw0` (AirDrop and other Apple peer-to-peer links) and `utun…`
/// (VPN tunnels – VPN traffic also passes through the physical interface, so
/// counting both would count it twice).
///
/// ## Active interface
/// `SCDynamicStore` tells us which interface macOS currently routes internet
/// traffic through ("PrimaryInterface"), and `SCNetworkInterface` gives its
/// friendly name (e.g. "Wi-Fi"). The name lookup takes ~9 ms, so it is cached
/// and only repeated when the primary interface changes.
struct NetworkService {
    /// Raw byte counters for one interface.
    struct Counters: Equatable, Sendable {
        var received: UInt64
        var sent: UInt64
    }

    /// Result of comparing two readings.
    struct Delta: Equatable, Sendable {
        var receivedBytes: UInt64
        var sentBytes: UInt64
        var downloadPerSecond: Double
        var uploadPerSecond: Double
    }

    private var previous: [String: Counters] = [:]
    private var previousTime = ContinuousClock.now
    private var totalReceived: UInt64 = 0
    private var totalSent: UInt64 = 0

    private let store = SCDynamicStoreCreate(nil, "MacMonitor" as CFString, nil, nil)
    private var displayNames: [String: String] = [:]
    private var lastPrimary: String?

    init() {
        previous = Self.readCounters()
    }

    mutating func sample() -> NetworkStats {
        let now = ContinuousClock.now
        let current = Self.readCounters()
        let elapsed = now - previousTime
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

        let delta = Self.delta(previous: previous, current: current, seconds: seconds)
        previous = current
        previousTime = now
        totalReceived += delta.receivedBytes
        totalSent += delta.sentBytes

        let primary = primaryInterface()

        return NetworkStats(
            downloadBytesPerSecond: delta.downloadPerSecond,
            uploadBytesPerSecond: delta.uploadPerSecond,
            totalDownloaded: totalReceived,
            totalUploaded: totalSent,
            interfaceName: primary ?? "—",
            interfaceType: primary.map { displayName(for: $0) } ?? "Not connected",
            isConnected: primary != nil
        )
    }

    // MARK: - Pure logic (unit-tested)

    /// Physical network hardware only (see the type's documentation).
    static func isPhysical(_ name: String) -> Bool {
        name.hasPrefix("en")
    }

    /// Counters handed to normal apps wrap at this value (see type docs).
    static let wrapValue: UInt64 = 1 << 32

    /// Bytes between two readings of one counter. Handles a 32-bit wrap; a
    /// drop that can't be a wrap means the interface was reset (count 0).
    static func bytesBetween(_ before: UInt64, _ now: UInt64, seconds: Double) -> UInt64 {
        if now >= before { return now - before }
        // Could this be a wrap? Only if both values fit in 32 bits and the
        // implied traffic is physically possible (≤ 10 Gbit/s, with margin).
        let maxPlausible = UInt64(max(seconds, 1) * 2.5e9)
        if before < wrapValue {
            let wrapped = now + wrapValue - before
            if wrapped <= maxPlausible { return wrapped }
        }
        return 0
    }

    /// Bytes moved between two readings, summed over physical interfaces.
    static func delta(previous: [String: Counters], current: [String: Counters], seconds: Double) -> Delta {
        var received: UInt64 = 0
        var sent: UInt64 = 0
        for (name, now) in current where isPhysical(name) {
            // A new interface (e.g. a USB adapter just plugged in) has no
            // previous reading yet: start counting from the next sample.
            guard let before = previous[name] else { continue }
            received += bytesBetween(before.received, now.received, seconds: seconds)
            sent += bytesBetween(before.sent, now.sent, seconds: seconds)
        }
        guard seconds > 0 else { return Delta(receivedBytes: received, sentBytes: sent, downloadPerSecond: 0, uploadPerSecond: 0) }
        return Delta(receivedBytes: received, sentBytes: sent,
                     downloadPerSecond: Double(received) / seconds,
                     uploadPerSecond: Double(sent) / seconds)
    }

    // MARK: - System calls

    /// Reads the byte counters of every interface.
    static func readCounters() -> [String: Counters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return [:] }

        var result: [String: Counters] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            // The buffer is a list of variable-length messages; each header
            // says how long it is. `loadUnaligned` is needed because the
            // messages are not guaranteed to start on aligned addresses.
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2,
                   offset + MemoryLayout<if_msghdr2>.size <= length {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if let name = interfaceName(index: UInt32(info.ifm_index)) {
                        result[name] = Counters(received: info.ifm_data.ifi_ibytes, sent: info.ifm_data.ifi_obytes)
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return result
    }

    private static func interfaceName(index: UInt32) -> String? {
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        guard if_indextoname(index, &name) != nil else { return nil }
        return String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The interface macOS currently uses for internet traffic, if any.
    private func primaryInterface() -> String? {
        guard let store,
              let ipv4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return nil }
        return ipv4["PrimaryInterface"] as? String
    }

    /// "en0" → "Wi-Fi". Cached; refreshed only when the primary interface changes.
    private mutating func displayName(for bsdName: String) -> String {
        if bsdName != lastPrimary || displayNames[bsdName] == nil {
            lastPrimary = bsdName
            displayNames = [:]
            for interface in (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? [] {
                if let name = SCNetworkInterfaceGetBSDName(interface) as String?,
                   let display = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? {
                    displayNames[name] = display
                }
            }
        }
        if let known = displayNames[bsdName] { return known }
        if bsdName.hasPrefix("utun") || bsdName.hasPrefix("ipsec") { return "VPN" }
        return bsdName
    }
}
