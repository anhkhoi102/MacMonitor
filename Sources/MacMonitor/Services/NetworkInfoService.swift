import Darwin
import Foundation

/// Local and public IPv4 addresses (Network page).
enum NetworkInfoService {
    /// One IPv4 address on one network interface.
    struct InterfaceAddress: Sendable, Equatable, Identifiable {
        let interface: String   // e.g. "en0"
        let address: String     // e.g. "192.168.1.100"
        var id: String { interface + address }

        /// Plain-English kind for interfaces that aren't the main one.
        var kind: String {
            if interface.hasPrefix("utun") || interface.hasPrefix("ipsec") || interface.hasPrefix("ppp") { return "VPN" }
            if interface.hasPrefix("bridge") { return "Bridge" }
            if interface.hasPrefix("en") { return "Network adapter" }
            return "Interface"
        }
    }

    // MARK: Local IPv4

    /// Every IPv4 address on interfaces that are up (loopback excluded).
    /// `getifaddrs` is the standard system call for this; it makes no network traffic.
    static func ipv4Addresses() -> [InterfaceAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var result: [InterfaceAddress] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            result.append(InterfaceAddress(interface: String(cString: entry.ifa_name), address: text))
        }
        return result
    }

    /// Splits addresses into the one on the interface macOS uses for internet
    /// traffic (from `NetworkService`) and the rest (e.g. a VPN). Never just
    /// picks "the first" or assumes Wi-Fi.
    static func split(_ addresses: [InterfaceAddress], primaryInterface: String?)
        -> (primary: InterfaceAddress?, others: [InterfaceAddress])
    {
        guard let primaryInterface else { return (nil, addresses) }
        let primary = addresses.first { $0.interface == primaryInterface }
        return (primary, addresses.filter { $0 != primary })
    }

    // MARK: Public IPv4

    /// Cloudflare's trace page (also used by the speed test, so no new third
    /// party). Requesting it from the IPv4 address 1.1.1.1 guarantees the
    /// answer is your public *IPv4* address. HTTPS, no cookies, nothing sent
    /// except the request itself.
    static let publicIPURL = URL(string: "https://1.1.1.1/cdn-cgi/trace")!

    enum PublicIPError: LocalizedError, Equatable {
        case offline, timedOut, unexpectedResponse, other(String)

        var errorDescription: String? {
            switch self {
            case .offline: "You appear to be offline."
            case .timedOut: "The lookup timed out."
            case .unexpectedResponse: "The lookup service sent an unexpected answer."
            case .other(let message): message
            }
        }
    }

    @concurrent
    static func fetchPublicIPv4() async throws -> String {
        let configuration = URLSessionConfiguration.ephemeral   // no cookies or cache kept
        configuration.timeoutIntervalForRequest = 8
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(from: publicIPURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let ip = parseTrace(String(decoding: data, as: UTF8.self)) else {
                throw PublicIPError.unexpectedResponse
            }
            return ip
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost: throw PublicIPError.offline
            case .timedOut: throw PublicIPError.timedOut
            case .cancelled: throw CancellationError()
            default: throw PublicIPError.other(error.localizedDescription)
            }
        }
    }

    /// Reads the "ip=" line and accepts it only if it is a valid IPv4 address.
    static func parseTrace(_ text: String) -> String? {
        for line in text.split(separator: "\n") where line.hasPrefix("ip=") {
            let value = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            return isValidIPv4(value) ? value : nil
        }
        return nil
    }

    static func isValidIPv4(_ text: String) -> Bool {
        var address = in_addr()
        return text.withCString { inet_pton(AF_INET, $0, &address) } == 1
    }
}
