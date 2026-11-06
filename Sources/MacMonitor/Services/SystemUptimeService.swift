import Darwin
import Foundation

/// How long the Mac has been running since its last start (Battery page).
///
/// The kernel records the moment it booted in `kern.boottime` (the same value
/// `sysctl kern.boottime` and `uptime` use). Uptime = now − boot time. This is
/// *system* uptime: it is not when you logged in or when MacMonitor started.
/// (Time spent asleep counts too, the same as `uptime`.)
enum SystemUptimeService {
    /// The last boot, or nil if the kernel doesn't answer.
    static func bootDate() -> Date? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1_000_000)
    }

    /// "2 days, 5 hours, 32 minutes" (localized, minute precision).
    static func formatUptime(from boot: Date, to now: Date = Date(), locale: Locale = .current) -> String {
        let seconds = max(0, now.timeIntervalSince(boot))
        let formatter = DateComponentsFormatter()
        var calendar = Calendar.current
        calendar.locale = locale
        formatter.calendar = calendar
        formatter.allowedUnits = seconds >= 86_400 ? [.day, .hour, .minute] : [.hour, .minute]
        formatter.unitsStyle = .full
        formatter.zeroFormattingBehavior = .dropLeading
        return formatter.string(from: seconds) ?? "—"
    }
}
