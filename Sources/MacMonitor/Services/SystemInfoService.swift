import Darwin
import Foundation
import IOKit

/// Facts about this Mac and its macOS installation (Information page).
/// Everything is read locally with native APIs (`sysctl`, the I/O Registry,
/// `ProcessInfo`) – no command-line tools, no network, no special permission.
struct SystemInfo: Sendable, Equatable {
    // macOS
    var osVersion: String          // "27.0.1"
    var osBuild: String            // "26A434"
    var kernelVersion: String      // "Darwin 27.0.0"
    var bootDate: Date?
    // Mac
    var modelName: String?         // "MacBook Air (M1, 2020)" – nil if macOS doesn't provide one
    var modelIdentifier: String    // "MacBookAir10,1"
    /// Board ID used by Apple's update catalog to say which Macs a macOS
    /// release supports (e.g. "J313AP" on Apple Silicon, "Mac-…" on Intel).
    var boardID: String?
    var chip: String               // "Apple M1"
    var performanceCores: Int
    var efficiencyCores: Int
    var totalCores: Int
    var memoryBytes: UInt64
    var gpuName: String?
    var gpuCores: Int?
    var serialNumber: String?
    var isAppleSilicon: Bool

    var architecture: String { isAppleSilicon ? "Apple Silicon (arm64)" : "Intel (x86_64)" }

    var coreDescription: String {
        guard performanceCores > 0, efficiencyCores > 0 else { return "\(totalCores) cores" }
        return "\(totalCores) cores (\(performanceCores) performance + \(efficiencyCores) efficiency)"
    }
}

enum SystemInfoService {
    static func collect() -> SystemInfo {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let versionString = version.patchVersion > 0
            ? "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            : "\(version.majorVersion).\(version.minorVersion)"
        let isAppleSilicon = (Sysctl.int("hw.optional.arm64") ?? 0) == 1
        let gpu = gpuInfo()
        return SystemInfo(
            osVersion: versionString,
            osBuild: Sysctl.string("kern.osversion") ?? "—",
            kernelVersion: "Darwin " + (Sysctl.string("kern.osrelease") ?? "—"),
            bootDate: SystemUptimeService.bootDate(),
            modelName: registryString(plane: kIODeviceTreePlane, path: "IODeviceTree:/product", key: "product-name"),
            modelIdentifier: Sysctl.string("hw.model") ?? "—",
            boardID: isAppleSilicon ? Sysctl.string("hw.target")
                : platformString(key: "board-id"),
            chip: Sysctl.string("machdep.cpu.brand_string") ?? "—",
            performanceCores: Sysctl.int("hw.perflevel0.physicalcpu") ?? 0,
            efficiencyCores: Sysctl.int("hw.perflevel1.physicalcpu") ?? 0,
            totalCores: Sysctl.int("hw.physicalcpu") ?? ProcessInfo.processInfo.processorCount,
            memoryBytes: Sysctl.uint64("hw.memsize") ?? 0,
            gpuName: gpu.name,
            gpuCores: gpu.cores,
            serialNumber: platformString(key: kIOPlatformSerialNumberKey),
            isAppleSilicon: isAppleSilicon)
    }

    // MARK: I/O Registry helpers

    /// A string or data property of the platform device (serial number, board ID).
    private static func platformString(key: String) -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return value(IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue())
    }

    /// e.g. the marketing model name stored in the device tree on Apple Silicon.
    private static func registryString(plane: String, path: String, key: String) -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, path)
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        return value(IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue())
    }

    /// Apple Silicon GPU name and core count (nil on Macs that don't publish them).
    private static func gpuInfo() -> (name: String?, cores: Int?) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        guard service != 0 else { return (nil, nil) }
        defer { IOObjectRelease(service) }
        let name = value(IORegistryEntryCreateCFProperty(service, "model" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue())
        let cores = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber
        return (name, cores?.intValue)
    }

    /// Registry values are either strings or NUL-terminated byte data.
    static func value(_ raw: Any?) -> String? {
        if let string = raw as? String { return string.isEmpty ? nil : string }
        if let data = raw as? Data {
            let text = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
            return text.isEmpty ? nil : text
        }
        return nil
    }
}
