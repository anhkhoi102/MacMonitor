# MacMonitor

A lightweight, native macOS system monitor and storage cleaner, written in Swift +
SwiftUI and built **without full Xcode**, using only the Command Line Tools.

**Status: all 11 phases, the feature enhancement and the pre-release update complete (v1.5.0).** What the app does:
- **Monitoring is real:** CPU, memory (including Memory by App and Memory by Type),
  storage, battery and network.
- **Internet speed test:** runs on demand, using Cloudflare.
- **Storage Cleaner:** scans only when you ask. You choose what to clean and confirm it.
  Approved items are re-checked and **moved to the Trash**; items open in a running app
  are skipped.
- **Background:** monitoring pauses while the window can't be seen.

| Phase | What | Status |
|---|---|---|
| 1 | Swift Package setup, no Xcode | ✅ |
| 2 | SwiftUI dashboard with mock data | ✅ |
| 3 | Real CPU monitoring (total, user, system, idle, per core) | ✅ |
| 4 | Real memory monitoring (used, available, pressure, swap) | ✅ |
| 5 | Real disk monitoring (capacity, used, available, purgeable) | ✅ |
| + | Memory by App, Memory by Type, Battery page | ✅ |
| 6 | Real network monitoring (speeds, session totals, active interface) | ✅ |
| 7 | Internet speed test (Cloudflare endpoints, no install) | ✅ |
| 8 | Cleaner: scanning and analysis (read-only) | ✅ |
| 9 | Cleaner: select items + confirmation workflow | ✅ |
| 10 | Cleaner: safe cleanup via the Trash | ✅ |
| 11 | Polish + performance: background pause, app icon, launch at login, ⌘1–⌘8, VoiceOver | ✅ |
| E2 | Process Monitor + End Process, System Uptime, Wi-Fi name, local/public IPv4, CPU temperature status | ✅ |
| E3 | Disk Space Analyzer, app last-used dates, category-level Cleaner selection | ✅ |
| E4 | Flush DNS Cache (macOS administrator dialog) | ✅ |
| E5 | Integration and validation | ✅ |
| P1 | Pre-release: US English, hidden CPU temperature, Information page, Power page | ✅ |

---

## Requirements

- Apple Silicon Mac, macOS 14 or newer (developed on macOS 27)
- Xcode **Command Line Tools** (`xcode-select --install`). Full Xcode is not needed.

Check your setup:

```bash
swift --version          # Apple Swift 6.x
xcode-select -p          # /Library/Developer/CommandLineTools
xcrun --show-sdk-version # 27.0
```

## Build and run

**Fast development loop.** Compiles a debug build and runs it straight from the terminal:

```bash
swift run
```

**Debug build only.** Checks that everything compiles:

```bash
swift build
```

**Run the unit tests** (Swift Testing):

```bash
swift test
```

**Package as an app.** Optimized release build, wrapped as `build/MacMonitor.app`:

```bash
Scripts/build.sh
```

**Package and launch:**

```bash
Scripts/build.sh release --open
```

**Run the packaged app:**

```bash
open build/MacMonitor.app
```

You can also double-click `build/MacMonitor.app` in Finder or drag it into
`/Applications`. It runs on its own, with no terminal or editor open.

**Screenshots of every page in light and dark mode.** Saved to `./snapshots`. Pages
longer than the window are also saved in full as `*-full.png`:

```bash
Scripts/snapshot.sh
```

> The first `swift build` takes about 40 s. Later builds only recompile files you changed.
> Two `ld: warning: search path ... not found` lines are normal with the Command Line
> Tools and can be ignored.

---

## Project layout

```
MacMonitor/
├── Package.swift                 # SwiftPM manifest: one executable target, macOS 14+
├── Scripts/
│   ├── build.sh                  # swift build → MacMonitor.app → ad-hoc signing
│   └── snapshot.sh               # renders every page to PNG (dev tool)
└── Sources/MacMonitor/
    ├── App/MacMonitorApp.swift   # @main entry point, window, AppDelegate
    ├── Models/                   # Plain data structs (CPUStats, MemoryStats, History, …)
    ├── Services/
    │   ├── CPUService.swift          # Real CPU usage from the Mach kernel (Phase 3)
    │   ├── MemoryService.swift       # Real RAM, pressure and swap (Phase 4)
    │   ├── DiskService.swift         # Startup-disk capacity, runs off the main thread (Phase 5)
    │   ├── ProcessMemoryService.swift # Memory by app (per-process footprint, grouped by .app)
    │   ├── BatteryService.swift      # Battery from the I/O Registry
    │   ├── NetworkService.swift      # Network speeds and active interface (Phase 6)
    │   ├── SpeedTestService.swift    # On-demand Internet speed test via Cloudflare (Phase 7)
    │   ├── CleanerScanner.swift      # Read-only scan of cleanup categories (Phase 8)
    │   ├── CleanupValidator.swift    # Re-checks approved items before cleanup (Phase 9)
    │   ├── OpenFilesSnapshot.swift   # Which files running apps have open (Phase 10)
    │   └── CleanupExecutor.swift     # The only code that moves files: to the Trash (Phase 10)
    ├── ViewModels/
    │   └── DashboardViewModel.swift  # @Observable state + shared 1-second refresh clock
    ├── Views/
    │   ├── ContentView.swift     # Sidebar + page switching
    │   ├── DashboardView.swift   # Overview
    │   ├── CPUView.swift, MemoryView.swift, StorageView.swift,
    │   ├── NetworkView.swift, CleanerView.swift, SettingsView.swift
    │   └── Components/
    │       ├── Components.swift      # Card, RingGauge, UsageBar, StatTile, …
    │       └── SparklineChart.swift  # Lightweight Canvas line chart
    └── Utilities/
        ├── AppSettings.swift     # Settings keys, appearance, units
        ├── Formatters.swift      # Bytes, GB, %, speed → strings
        ├── Sysctl.swift          # Reads hardware facts (CPU model, core counts)
        ├── ViewState.swift       # @State workaround for Command Line Tools (see below)
        └── SnapshotExporter.swift
Tests/MacMonitorTests/            # `swift test`: 128 tests (no network; fake home, fake Trash, fake Applications)
```

**How data flows:** each layer only talks to the one below it.

```
Views  ──read──▶  DashboardViewModel  ──calls──▶  Services  ──▶  macOS APIs
(SwiftUI)         (@Observable, main thread)      (mock today)
```

Views never call system APIs, so in Phases 3–6 we can swap the mock generator for real
services one metric at a time without touching the UI.

---

## Technical decisions (and why)

**SwiftUI `App` lifecycle, no storyboard or `.xcodeproj`.** Everything is Swift code that
`swiftc` compiles. An Xcode project file and asset catalogs need Xcode's tools
(`actool`, `ibtool`), and the Command Line Tools don't include them.

**The `.app` bundle is built by hand.** An app bundle is just a folder:
`Contents/MacOS/<binary>` plus `Contents/Info.plist`. `build.sh` creates it, then signs
it ad-hoc (`codesign --sign -`), which Apple Silicon requires before any binary will run.

**`@ViewState` instead of `@State`.** This is a Command Line Tools limitation we hit. In
the macOS 27 SDK, `@State` is declared both as the classic property wrapper and as a
Swift macro. The compiler picks the macro, and the macro's implementation
(`SwiftUIMacros`) only ships with full Xcode, so the build fails with
`plugin for module 'SwiftUIMacros' not found`. `ViewState` is a typealias for the same
property wrapper with no macro attached. It behaves exactly like `@State`.
`@Observable` still works because its macro plugin *is* included in the Command Line
Tools. For the same reason, `#Preview` blocks won't work, so don't add them.

**Tests use Swift Testing, plus one compiler flag.** XCTest ships only with full Xcode,
but Swift Testing (`import Testing`, `@Test`, `#expect`) is included in the Command
Line Tools. As with `@State`, SwiftPM doesn't pass the `@Test` macro plugin to the
compiler on its own, even though the plugin is installed. The test target in
`Package.swift` adds `-plugin-path …/host/plugins/testing` to fix that. The flag only
affects tests, not the app.

**How CPU usage is measured (Phase 3).** For each core, the kernel counts "ticks" spent
in user code, kernel (system) code, low-priority (nice) code, and idle.
`host_processor_info(PROCESSOR_CPU_LOAD_INFO)` returns all of these counters in one
call that takes a few microseconds. A single reading means nothing because the counters
started at boot, so `CPUService` reads them once per interval and works out
percentages from the **difference**. Nice time counts as User, like Activity Monitor
does. On Apple Silicon the kernel lists Efficiency cores first, and the counts come
from `sysctl hw.perflevel1.logicalcpu` (E) and `hw.perflevel0.logicalcpu` (P). The
maths is a pure function (`CPUService.makeStats`), so it is unit-tested with made-up
counters, including the 32-bit counter wrapping back to zero.

*Verified against `top`* with 4 busy processes on the 8-core M1:

| | User | System | Idle |
|---|---|---|---|
| MacMonitor | 19% | 54% | 28% |
| `top` | 10–18% | 51–62% | 25–38% |

All 4 Performance cores read 100%.

The CPU page also shows **"MacMonitor itself"**: the app's own CPU use, measured with
`getrusage`. That way you can check at any time that monitoring stays cheap.

**`@Observable` + `@MainActor` view model.** Views re-render automatically when a
property they read changes. `@MainActor` guarantees all UI state is touched only on the
main thread. Swift 6 checks this when compiling.

**Refresh loop = one `async` loop in `.task {}` acting as a shared 1-second clock.**
There's no `Timer` to forget to invalidate, and SwiftUI cancels the loop when the
window closes. Each metric refreshes on the ticks that match its interval from Settings
(CPU and network every 1 s, memory every 2 s, disk every 10 s by default). A first
version used a separate loop per metric. Those loops drifted apart, so the window
redrew twice per second and CPU use went up from ~1.5% to ~8%. One clock means one
redraw per second.

**Bounded history.** Charts keep at most N samples (2 minutes by default, set in
Settings), so memory use can't grow over time.

**A custom Canvas chart instead of Swift Charts for live graphs.** These were measured on
the Overview page with a release build:

| Version | CPU |
|---|---|
| First version (Swift Charts, shadows, 0.5 s animations) | ~29% |
| Without card shadows and smoothed curves | ~14% |
| Canvas sparklines, no per-second animations | ~2–3% |
| Phase 3: real CPU sampling + one shared clock | ~1.5% |
| Phase 4: + real memory sampling | ~1.5–1.9% |
| Phase 5: + real disk capacity (every 10 s, background) | ~1.7–1.8% |
| + battery (every 10 s); per-app scan only on the Memory page | ~2% |
| Phase 6: + real network counters every second | **~2.2–2.3%** |

Swift Charts lays out one "mark" per data point, so 4 charts × 120 points every second
adds up. `SparklineChart` strokes a single `Path` per line instead. Swift Charts is still
used for the static donuts (storage, memory by type). Memory footprint is about 57 MB, well under the
100 MB target. These are measurements on one machine, not guarantees.

**How memory is measured (Phase 4).** RAM is managed in 16 KB *pages*.
`host_statistics64(HOST_VM_INFO64)` returns how many pages are in each state. It's the
same data the `vm_stat` command prints. `MemoryService` converts these counts the way
Activity Monitor does:

| Value | Formula |
|---|---|
| App Memory | anonymous pages − purgeable pages |
| Wired | wired pages (kernel memory that never moves) |
| Compressed | pages occupied by the compressor |
| Cached Files | file-backed + purgeable pages (dropped instantly when needed) |
| **Used** | **App + Wired + Compressed** |
| Available | Total − Used |

We deliberately do **not** use "Total − Free". macOS fills spare RAM with file cache, so
"free" is always close to zero even when plenty of memory is available. A unit test
checks this case.

**How disk capacity is measured (Phase 5).** `DiskService` asks the file system about
the volume that contains `/` using `URL.resourceValues(forKeys:)`. On modern macOS, `/`
is a read-only system volume that shares one APFS container with your data, so the
totals are for the whole container. These are the same figures as Finder and
`diskutil info /`. There are two "available" values:

| Value | Key | Matches |
|---|---|---|
| **Available** | `volumeAvailableCapacityForImportantUsageKey` | Finder: free + purgeable |
| Free now | `volumeAvailableCapacityKey` | `df` / `diskutil` |
| Purgeable | Available − Free now | Caches and snapshots macOS clears automatically |

Used = Total − Available, the same way Finder counts it. The service only reads sizes. It
never opens, changes or deletes files.

**First background work: `@concurrent`.** This query took **14–44 ms** on the M1. The
screen redraws every 8–16 ms, so running it on the main thread could cause a visible
stutter. `DiskService.sample()` is marked `@concurrent` (Swift 6.2+), which makes it run
on a background thread. The view model `await`s the result and updates the UI back on
the main actor. A flag stops a second query from starting while one is still running.
The view model also only assigns new values when something changed, so a steady disk
doesn't cause redraws.

*Verified at the same moment:* MacMonitor's total and free space matched `diskutil`'s
container total and container free to within 0.01 GB. Finder-style Available is a few
GB higher because it also counts purgeable space.

**Memory by Type.** This is the same page counts shown as a donut, with a one-line
explanation of each type. App Memory, Wired, Compressed, Cached Files and Free come
straight from the kernel. "Other" is whatever remains (pages in transition), so the
slices always add up to the installed RAM.

**Memory by App.** `ProcessMemoryService` works in three steps:

1. Lists every process (`proc_listallpids`).
2. Reads each process's **physical footprint** (`proc_pid_rusage`), the same number as
   Activity Monitor's Memory column.
3. Groups processes by the outermost `.app` bundle in their path, so Chrome's helper
   processes add up under "Google Chrome".

Scanning ~570 processes takes about **4 ms** on a background thread. It only runs every
5 s **while the Memory page is open**: it's started by that page's `.task {}`, and
SwiftUI cancels it when you leave the page.

*Limits:*
- macOS only lets a normal app read processes owned by the same user. System processes
  such as WindowServer and root daemons, typically about 200, are counted as "not
  shown" instead. MacMonitor never asks for admin rights.
- Footprint includes compressed and swapped memory, so the list can add up to more than
  "Used".

*Verified against `top`:* the largest apps matched within about 1% (for example 815 vs
812 MB). The two tools read a moment apart, so small differences are expected.

**Battery.** `BatteryService` reads the `AppleSmartBattery` entry in the I/O Registry
(`ioreg -rn AppleSmartBattery` shows the raw data). It reads: charge, charging state,
time remaining, cycle count, voltage and current (power = V × A), adapter wattage, and
design vs current full-charge capacity. It needs no permissions and runs every 10 s on
a background thread. Desktop Macs without a battery get a "No Battery" message.

*Verified against `pmset -g batt`:* charge, charging state and time remaining match
(within a minute); cycle count matches System Information; adapter wattage matches.

*Limits:*
- **Health is an estimate** (full-charge ÷ design capacity). System Settings
  may show a few percent more because Apple uses its own, unpublished method. The page says so.
- **Battery temperature isn't shown.** macOS 27 no longer publishes it to normal apps,
  so there's no temperature setting.
- A "Plugged in, not charging" state is normal when macOS pauses charging to protect
  the battery.

**How network speed is measured (Phase 6).** The kernel counts the bytes each network
interface has received and sent. `NetworkService` reads those counters every second
with `sysctl(NET_RT_IFLIST2)`, the same data as `netstat -ib`. Speed is
(bytes now − bytes before) ÷ seconds elapsed, using the real elapsed time from a clock
rather than assuming exactly 1 s.

- **Only physical hardware is counted:** interfaces named `en…` (Wi-Fi, Ethernet,
  USB/Thunderbolt adapters). `lo0` (traffic inside the Mac), `awdl0`/`llw0` (AirDrop)
  and `utun…` (VPN) are skipped. VPN traffic also passes through Wi-Fi or Ethernet, so
  counting the tunnel too would count it twice.
- **Active interface:** `SCDynamicStore` reports the interface macOS routes internet
  traffic through. `SCNetworkInterface` turns "en0" into "Wi-Fi". That name lookup takes
  ~9 ms, so it's cached and only repeated when the active interface changes.
- **MacMonitor sends no network traffic of its own.** It only reads counters macOS
  already keeps.

*A macOS privacy limit, found while testing:* Apple's own tools (`netstat`) get exact
64-bit counters. Ordinary apps get them **cut to 32 bits**, so they wrap back to 0
every 4 GB, and **rounded to 1 KB**. In testing, after tens of GB of traffic, netstat's
total minus a whole number of 4 GB wraps equaled exactly what MacMonitor was given.
Consequences:

- **Speeds and session totals are still correct.** They only use the difference between
  readings a second apart. `NetworkService.bytesBetween` recognizes a wrap (e.g.
  4.29 GB → 0.01 GB = +20 MB) and tells it apart from an interface reset: a wrap is
  only accepted if the traffic it implies is physically possible.
- **"Total since the Mac started" can't be known by an app,** so the Network page shows
  totals since MacMonitor opened ("session") instead.
- **Speed resolution is 1 KB/s.**

*Verified:* MacMonitor's raw counter equals netstat's value with the 4 GB wraps removed
and rounded to the KB. Session totals tracked netstat's change over the same seconds to
within a few KB, and the remaining gap comes from the two readings not being perfectly
simultaneous.

Small speeds switch units automatically ("12 KB/s" instead of "0.01 MB/s"). The chart
axis is labeled the same way.

**Internet speed test (Phase 7).** Your spec suggested Ookla's Speedtest CLI, which
would need a separate install. Ookla has no public API, and its terms forbid automated
use of speedtest.net's internal endpoints. So `SpeedTestService` uses **Cloudflare's
public speed-test endpoints** instead. These are the same ones speed.cloudflare.com
and Cloudflare's open-source test library use:

| Step | Request | How it's measured |
|---|---|---|
| Ping & jitter | 20 × `GET /__down?bytes=0` over one open connection | Time to first byte minus Cloudflare's processing time (`Server-Timing`). Ping = median; jitter = average change between consecutive samples |
| Download | `GET /__down?bytes=N`, 100 KB growing 4× (max 50 MB), within 150 MB / 10 s | Bytes × 8 ÷ time the body took to arrive; 90th percentile of transfers ≥ 0.2 s |
| Upload | `POST /__up`, same growth (max 25 MB), within 60 MB / 10 s | Bytes × 8 ÷ the server's own receive time (`cfSpeedWorker`) |
| Server | `CF-RAY` header ends in the data-center code, e.g. `-SJC` | Shown as "Cloudflare · San Jose (SJC)" |

How it behaves:
- **Starts only when you press Run Speed Test.** There's a progress bar with the
  current phase and live Mbps, and a Cancel button.
- **Never runs on its own,** and it's independent of the live network monitor.
- **Data use:** about 200 MB per test. The page says so next to the button.
- **Errors** such as being offline, a timeout or a blocked server get plain-English
  messages.
- **The last result is saved** in UserDefaults, so it's still there next launch.

Timing comes from `URLSessionTaskMetrics`, the exact moments the request started and
the response began and ended, rather than a stopwatch that would include the app's own
overhead.

*Bug found while testing:* the first real run reported 117,417 Mbps upload. Checking
with `curl` showed that for uploads, `cfSpeedWorker` is the time the server spent
*receiving* the body (788 ms for 10 MB), not processing time. The code now uses it as
the upload duration, and a unit test pins this down.

*Verified (back-to-back runs on Wi-Fi):*

| | Download | Upload | Ping | Jitter |
|---|---|---|---|---|
| MacMonitor (Cloudflare) | ~190 Mbps | ~180 Mbps | ~50 ms | ~10 ms |
| Apple `networkQuality` | ~145 Mbps | ~150 Mbps | ~75 ms (to Apple's servers) | — |
| ICMP `ping` to Cloudflare | | | ~40 ms | |

The results are in the same range. They differ because the servers differ and Wi-Fi
varies from one moment to the next. Like Cloudflare's own test, it uses a **single
connection**, so very fast lines (over ~500 Mbps) may score lower than multi-connection
tests.

*Developer check:* `MACMONITOR_DEV_SPEEDTEST=<folder>
build/MacMonitor.app/Contents/MacOS/MacMonitor` runs one test, writes a progress log
and a screenshot to that folder, then quits.

**Storage Cleaner scan (Phase 8).** `CleanerScanner` is **read-only**: the file has no
code that moves, changes or deletes anything. A scan only starts when you press **Scan**.
It takes about half a second on this Mac and can be canceled.

| Category | Where it looks | Risk |
|---|---|---|
| Application Caches | each folder in `~/Library/Caches` (minus the ones below) | Low; Medium for `com.apple.*` |
| Browser Caches | recognized cache folders only: Safari, Chrome, Firefox, Edge, Brave, Opera, Vivaldi, Arc, Cốc Cốc | Low |
| Application Logs | `~/Library/Logs` (except DiagnosticReports) | Low |
| Temporary Files | your temp folder, items unchanged for 3+ days, not `com.apple.*` | Medium |
| Old Crash / Diagnostic Reports | `~/Library/Logs/DiagnosticReports`, older than 30 days | Low |
| Trash Bin | `~/.Trash` | High (removal is permanent) |
| Xcode Caches | DerivedData, CoreSimulator caches, device support | Low / Medium |
| Developer Caches | Homebrew, pip, npm, Swift PM, Yarn, CocoaPods, Go, Gradle, Cargo download caches | Low |
| Large Files | files over 500 MB in Downloads, Desktop, Documents, Movies (opt-in) | High (review only) |

Anything changed in the last 24 hours moves up to at least Medium, because an app may be
using it right now. Large files are never counted as "recoverable".

Safety rules, each covered by a unit test:
- **Only fixed, recognized folders** in your home folder and temp folder. Browser
  *caches* only: profiles, cookies, passwords and history are never opened.
- **Symbolic links** are never followed or listed.
- **Sockets, pipes and device files** are never listed. *Found in the first real scan:*
  13 sockets of running programs, including a VS Code one, sat in the temp folder.
- **Empty items** are skipped.
- **Only your own files:** items must be owned by you (`lstat`).
- **Every item remembers its approved root folder.** A path-escape such as `root/../etc`
  is rejected.
- **Scanning changes nothing.** A test compares a fake home folder before and after a
  full scan.

*Protected folders:* macOS guards the **Trash** and **Safari's cache** behind *Full Disk
Access*. Those rows say so and offer a **Grant Access…** button. It only opens System
Settings › Privacy & Security › Full Disk Access; whether to grant access is your
choice. MacMonitor never requests admin rights.

The review list for each category shows name, size, date modified, risk, and location.
It sorts by name, size or date. Double-click a row, or use ⓘ, for details and the
reason for its risk level. 🔍 or the right-click menu opens **Show in Finder**.

*Verified:* a full scan takes under a second. Sizes match `du` once units are
converted (MacMonitor uses GB = 1000³, `du` uses GiB = 1024³, e.g. 1.62 GB = 1.5 GiB).

*Developer check:* `MACMONITOR_DEV_SCAN=<folder>
build/MacMonitor.app/Contents/MacOS/MacMonitor` runs one scan, writes a text summary
and screenshots, then quits.

**Approval workflow (Phase 9).** These are the eight steps from the spec, and where each
one lives:

| Step | What happens | Where |
|---|---|---|
| 1. Scan | Only when you press **Scan** | `CleanerScanner` |
| 2. Report | Dashboard: recoverable size, files, breakdown | `CleanerView` |
| 3. Display items | Review list per category | `CleanerCategoryView` |
| 4. You select | Checkboxes; **nothing is pre-selected**. Select All / Select Low Risk / Deselect All per category. A bar at the bottom shows the running total. | view model `cleanerSelection` |
| 5. Confirmation screen | Item count, total size, categories, the exact list of files and folders with their risk, and the warnings | `ConfirmCleanupSheet` |
| 6. Explicit confirmation | Only a click on **Confirm Cleanup** continues. Esc = Cancel, and Return does nothing, so it can't be confirmed by accident. Trash items need an extra "permanently deleted" checkbox. | `ConfirmCleanupSheet` |
| 7. Cleanup | Each item is re-checked, then moved to the Trash. A progress bar and **Stop** are shown | `CleanupExecutor` |
| 8. Results | Space freed, items moved, and what was skipped and why; **Open Trash** button | `CleanupResultView` |

How the scope is kept exactly to what you approved:
- Confirming creates a **`CleanupPlan`**, a frozen copy of the selected items.
  Changing the selection afterwards doesn't change it.
- Only that exact plan can be confirmed: the view model checks its ID.
- A new scan clears any selection and any open confirmation.

**Re-validation:** files can change between scanning and confirming. So
`CleanupValidator` checks every approved item again. Anything that fails is
**skipped**, never widened or "fixed":

1. Its folder is one of the scanner's approved roots.
2. It is strictly inside that root (no `..`, never the root itself).
3. It is not under a system location (`/System`, `/usr`, `/Applications`, …).
4. It still exists; if not, it's shown as "already gone".
5. It is still a plain file or folder, not a symbolic link or socket.
6. It is the same kind (file or folder) as when scanned.
7. It is still owned by you.
8. It hasn't been modified since the scan; if it has, rescan first.

Tests simulate each attack or change on a fake home folder: a folder swapped for a
symlink to Documents, a forged `/etc/hosts` item, a `../..` path, a deleted item, and a
modified item.

**Safe cleanup (Phase 10).** `CleanupExecutor` is the **only** code in MacMonitor that
moves or deletes files, and it only ever receives the frozen, confirmed plan. For each
item, one at a time:

1. **Stop pressed?** Leave this item and all the rest untouched.
2. **Re-check** it with all 8 validator rules, immediately before acting.
3. **In use?** If a running program has the item, or any file inside it, open, skip it
   and name the program. `OpenFilesSnapshot` reads each of your processes' open files
   from the kernel (`proc_pidinfo` / `proc_pidfdinfo`, like `lsof`) once, just before
   cleanup starts.
4. **Act:**
   - Normal items are moved with `FileManager.trashItem`, the same as Finder's Move to
     Trash, so **File › Put Back** works.
   - Items already in the Trash are deleted permanently, and only if you ticked the
     separate "permanently deleted" box.
5. **Record** the result. Permission errors and busy files become plain-English messages.

It never uses `rm -rf` or `sudo`, and never asks for admin rights. If an item turns
into a symbolic link between the check and the move, moving it moves the link itself,
never what the link points to.

*Bugs the tests caught:* Apple's `resolvingSymlinksInPath()` and `standardizedFileURL`
both silently strip `/private` from paths. The kernel reports open files as
`/private/var/folders/…`, so items in the temp folder never matched and were never seen
as "in use". `CleanupValidator.canonical` now uses the C library's `realpath`. A test
opens a real file and checks it's detected.

*Verified end to end on this Mac, using only throwaway folders.* The developer
self-test is hard-coded to select nothing but items named `MacMonitorSelfTest-…`:

| Test folder | Result |
|---|---|
| `MacMonitorSelfTest-free` (504 KB) | **Moved to Trash**; gone from Caches |
| `MacMonitorSelfTest-inuse`, held open by `tail -f` | **Skipped**: "Open in tail" |
| `MacMonitorSelfTest-free`, now found *in* the Trash, permanent deletion not confirmed | **Left alone** |

Unit tests use a **fake Trash folder**, so they never touch your real Trash. They cover:
- only approved items are moved, and every other file is unchanged;
- in-use items are skipped;
- a folder swapped for a symlink is skipped, and its target is untouched;
- Trash items need the separate confirmation;
- Stop leaves the remaining items untouched;
- errors become plain-English messages.

*Developer self-test:* `MACMONITOR_DEV_CLEANUP=<folder>
build/MacMonitor.app/Contents/MacOS/MacMonitor` runs the real workflow on items named
`MacMonitorSelfTest-…` only. If there are none, it does nothing.

**Utilization ≠ pressure.** Utilization (Used ÷ Total) is often high, and that's
healthy. Pressure is how hard macOS has to work, by compressing memory and swapping to
the SSD, to keep up. It comes from two kernel values that the `memory_pressure` command
also uses: the level (`kern.memorystatus_vm_pressure_level`: 1 Normal, 2 Warning,
4 Critical) and the available percentage (`kern.memorystatus_level`). The gauge shows
100 − available %, and its color follows the kernel's level. Swap comes from
`sysctl vm.swapusage`.

*Verified at the same moment against the reference tools:*

| | App | Compressed | Cached | Used | Pressure | Swap |
|---|---|---|---|---|---|---|
| MacMonitor | 2.4 GB | 1.1 GB | 2.3 GB | 5.1 GB | 36%, Normal | 1.8 / 3.0 GB |
| `vm_stat`, `memory_pressure`, `sysctl` | 2.43 GB | 1.11 GB | 2.31 GB | 5.09 GB | 64% free, level 1 | 1877 / 3072 MB |

**Polish and performance (Phase 11).**

- **Background pause.** The app watches the window's *occlusion state*, the macOS
  notification that says whether any part of a window can be seen, plus app hide and
  unhide. When nothing is visible, the 1-second loop skips all sampling, and the
  Memory-by-App scan waits too. A running speed test or cleanup carries on. At launch the
  window is brought back if macOS restored it minimized, and visibility is checked once,
  because no "changed" notification arrives in that case.
- **App icon.** `Scripts/make-icon.swift` draws the icon with AppKit at all 10 sizes.
  Apple's built-in `iconutil` packs them into `AppIcon.icns`, and `build.sh` only
  redraws it when the script changes. No Xcode asset catalog is involved.
- **Launch at login.** This uses Apple's `SMAppService.mainApp`. It's off by default,
  and the switch always shows the real macOS state rather than a saved copy. If macOS
  needs approval or refuses, the page says so and offers **Open Login Items…**.
- **Settings.** The temperature setting was removed because there's no temperature data
  to apply it to. The Storage Cleaner's safety rules stay visible and can't be changed.
- **Keyboard.** The **Go** menu has ⌘1 Overview … ⌘8 Settings, and ⌘, also opens
  Settings. In the cleanup sheet, Esc cancels and Return does nothing.
- **VoiceOver.** Gauges, bars, stat tiles and rows are read as one item with a value,
  for example "CPU Total, 23%". Canvas charts are described in words: "latest 23%, peak
  61%".

*Measured on this Mac (release build, 20-second averages):*

| Situation | CPU | Memory |
|---|---|---|
| Overview / CPU / Network page, window visible | 1.7–3.1% | 47–58 MB |
| Storage / Battery / Cleaner / Settings, visible | ~1% | 44–56 MB |
| **Window hidden or minimized** (before Phase 11: ~2%) | **~0.1%** | ~50 MB |

All figures are under the 100 MB memory target. One noisy run measured the Memory page
at 15.9%. A profile taken straight after showed it idle, so it was most likely the
one-time first scan of 300+ app icons; the page measures ~0.2–2.3% normally. These are
measurements on one machine, not guarantees.

*Developer options* used for these checks, all no-ops unless set:
- `MACMONITOR_START_PAGE=memory` opens a given page at launch.
- `MACMONITOR_DEV_FRONT=1` brings the window to the front.
- `MACMONITOR_DEV_BACKGROUND=hide|minimize` hides or minimizes the window after 3 s.

**Feature enhancement, phase 2.**

*Process Monitor* (`ProcessMonitorService`, `ProcessTerminator`, `ProcessViews.swift`):
- **Where:** a "Top Processes" card on the Overview (top 5, CPU/Memory switch), and a
  full **Processes** page (⌘7) with search, sortable column headers, details and
  End Process.
- **CPU %** is a share of *total CPU capacity*: all 8 cores busy = 100%, like Windows
  Task Manager. The kernel's per-process CPU time (in mach ticks, converted with
  `mach_timebase_info`, 125/3 ns on M1) is compared between samples. The details sheet
  also shows Activity Monitor's "% of one core". The sample key includes the process
  start time, so a reused PID never inherits CPU time.
- **Memory %** = physical footprint ÷ installed RAM.
- **Refresh:** every 3 s, only while the Overview or Processes page is on screen, and
  paused when the window is hidden. The scanner is an `actor`, so the work runs off the
  main thread.
- **Limits:**
  - Only your own processes are readable; about 200 system processes are counted, not
    listed.
  - macOS has no public "Not Responding" API, so Status shows the BSD process state.
    That is almost always "Running".
- **Verified against `top`** (× 8 cores): e.g. 0.6% of the Mac → 4.8% of one core vs
  top's 4.7%, with the same memory in both.

*End Process:* right-click → **End Process…** → confirmation dialog.
- **Graceful first:** apps get `NSRunningApplication.terminate()` (the same as Quit,
  so they can ask to save); other processes get `SIGTERM`.
- **Force Quit** is offered only if the process is still running after 5 s, with a
  warning that unsaved work will be lost.
- **Protected:** pid ≤ 1, MacMonitor itself, critical processes (WindowServer,
  loginwindow, Dock, …) and anything under `/System`, `/usr`, `/bin`, `/sbin`. Apps,
  including Apple's own like Notes, can be ended.
- **No `sudo`, no shell commands.** If macOS refuses (EPERM), the app says so.
- **Tests start real child processes:**
  - `sleep` ends on the graceful request;
  - a Perl process that ignores SIGTERM reports "still running" and only ends via
    Force;
  - ending launchd is refused.

*System Uptime* (Battery page, shown on every Mac): from `sysctl kern.boottime`,
updated every 30 s in your time zone. It's system uptime, including sleep, not login
time. Verified: matches `uptime` to the minute, and the boot time matches
`sysctl kern.boottime`.

*Connection details* (Network page):

| Field | Source | Notes |
|---|---|---|
| Network Interface | `SCDynamicStore` (existing) | |
| Connected Wi-Fi | CoreWLAN | Since macOS 14 the name requires **Location Services** permission. The **Allow Location Access…** button shows the macOS prompt; the app never reads your location. States: connected / not on Wi-Fi (e.g. Ethernet) / Wi-Fi off / no permission. Never cached. |
| Local IPv4 | `getifaddrs` | Uses the address on the *active* interface, not the first one found. VPNs and other adapters are listed separately. Verified against `ipconfig getifaddr en0`. |
| Public IPv4 | `https://1.1.1.1/cdn-cgi/trace` | Cloudflare, already used by the speed test. Connecting by IPv4 address guarantees an IPv4 answer. 8 s timeout, ephemeral session, only the `ip=` line is read and validated. Looked up at most every 15 min while the page is open, plus a manual ↻ button. |

*CPU temperature:* the Overview shows **"Temperature: Unavailable"** and the CPU page
explains why. The SMC (public IOKit calls) does report ~146 temperature sensors on this
M1, from 30 to 75 °C. But the key names are undocumented and changed in macOS 27, so
there's no reliable way to know which value is "the CPU temperature". Following the
spec, nothing guessed is shown. macOS's public **thermal state** (Nominal / Fair /
Serious / Critical) is shown instead and clearly labeled as a state.

*Two layout bugs found by measuring the real window:*
1. `Table` with rows that change every 3 s made AppKit log "reentrant operation in
   NSTableView delegate", which Apple says will become a crash. The stack contained only
   SwiftUI/AppKit frames. The Processes page now uses a lazy scrolling list.
2. A footnote with `fixedSize(vertical:)` next to a `Spacer` was squeezed to a sliver
   of width and grew thousands of points tall, stretching the whole window layout.
   Logging the real scroll-view frames (2,592 pt tall in a 785 pt window) found it.

**Feature enhancement, phase 3.**

*Disk Space Analyzer* (Storage page; `StorageAnalyzerService`, `StorageAnalyzerViews.swift`).
It is **read-only** and only runs when you press a button. It works on a background
thread and can be canceled. Results are cached for the session, and **Rescan**
refreshes them.

- **Applications mode:** every app in `/Applications` and `~/Applications`, including
  one level of sub-folders such as Utilities.
  - **App size** is everything inside the `.app` bundle.
  - **User Data (est.)** comes from Library locations named after the app's bundle ID or
    name: Application Support, Caches, Preferences, Logs, HTTPStorages, WebKit and
    Saved Application State. Each location is counted for **one app only**.
  - Sandboxed apps' `~/Library/Containers` folders are **not** opened, because since
    macOS 14 that triggers a privacy prompt per app.
  - Apple's apps in `/System/Applications` (on the read-only system volume) aren't
    listed.
- **Folders mode:** Downloads, Documents, Desktop, Movies, Home, or **Choose Folder…**
  (the standard macOS picker, which is also how macOS grants read access).
  - Shows the folder's contents ranked by size. Double-click a folder to go inside;
    ↑ goes up.
  - Privacy-protected data of other apps (Containers, Mail, Messages, Photos library…)
    is skipped and reported.
  - The whole disk is never scanned.
- **Table:** search, type filter, sort by size / last opened / name. Right-click →
  **Inspect** (size breakdown and the exact user-data paths), **Show in Finder**,
  **Copy Path**.

*Last opened* comes from Spotlight (`kMDItemLastUsedDate`) and is shown separately from
*Modified*. **Bug found by a test:** for items macOS has *no* usage record of, Spotlight
fills in the last-used date with the file's **creation date**. A never-launched fake app
came back "last used 2020-01-01". The date is therefore trusted only when Spotlight also
has a use count or usage dates; otherwise it shows "Unknown". Checked against `mdls`:
- Apps with no usage record (`mdls` shows null) show "Unknown".
- Apps with a use count show their last-used date.
- The date shown matches `mdls`'s time exactly.

*Verified:*
- App bundle and folder sizes match `du` (allowing for GB vs GiB).
- A few dozen apps take several seconds; a typical project folder under a second.

*Category-level Cleaner selection:*
- **Breakdown checkboxes:** each row in Breakdown by Category has a checkbox:
  - ☐ none selected;
  - ☑ all eligible items selected;
  - **–** some selected (mixed).
- **Toggling:** clicking it selects every eligible item, or deselects all when
  everything is already selected. Multiple categories work, and each row shows
  "N selected (size)".
- **Running total:** the bar at the bottom shows the overall total.
- **Item by item:** click a category to review and tick individual items, as before.
- **Large Files are now review-only.** Your spec says never to delete personal
  documents or downloads, so they have no checkbox and are refused at three levels:
  1. selection in the view model;
  2. `CleanupPlan.normalize`;
  3. the executor.
- **No double counting:** the plan drops an item that sits inside another selected
  folder, so nothing is counted or moved twice. The existing safety rules all still
  apply: confirmation screen, re-check, skipping in-use items, Trash only.

**Feature enhancement, phase 4: Flush DNS Cache** (Network page; `DNSFlushService`).

- **What it runs:** Apple's documented commands,
  `dscacheutil -flushcache && killall -HUP mDNSResponder`, as one fixed string with
  absolute paths. Nothing from user input is ever inserted.
- **Why it asks for your password:** the DNS resolver runs as a system user. As a normal
  user, `killall` fails ("No matching processes belonging to you"). `dscacheutil` alone
  succeeds without admin rights but doesn't clear mDNSResponder's cache, so reporting
  success after it alone would be dishonest.
- **How it asks:** the command runs through AppleScript's `with administrator
  privileges`, which shows the **standard macOS password / Touch ID dialog**. Your
  password goes to macOS, never to MacMonitor. There's no `sudo` and no stored password.
- **The flow:**
  1. **Flush DNS Cache…**
  2. A confirmation explains what will be cleared.
  3. The macOS dialog appears.
  4. The result shows: ✓ flushed at HH:MM / canceled / failed with the reason.
  The work runs in a separate process, so the app never freezes.
- **Success is shown only if macOS reports both commands succeeded.** Tests feed real
  `osascript` results into the parser: canceled (-128), a failing command and a
  succeeding one. *Not exercised live:* the real administrator dialog, which needs your
  password.

**Validation (phase 5):**
- **Build:** release build, the bundle keeps its icon and metadata, ad-hoc signature
  valid, arm64.
- **All 9 pages** captured in light and dark mode with **0 runtime warnings** in the
  logs.
- **Tests:** 114 pass.
- **Resource use** (release build, window visible, single 20 s runs, which vary by a few
  points):

| Page | CPU | Memory |
|---|---|---|
| Cleaner / Battery / Settings | 0.9–1.2% | 39–59 MB |
| Storage / Network / Processes | 1.8–2.7% | 58–69 MB |
| Overview / Memory / CPU | 3.2–6.0% | 69–73 MB |
| Window hidden or minimized | **0.05%** | 62 MB |

All under the 100 MB target.

**Pre-release update.**

*US English:* all user-facing text uses American spelling and wording. Examples:
Utilization, analyze, minimized, canceled, labeled, "check" instead of "tick", and
"AC power" instead of "AC power". Code names that come from Apple's APIs, such as
`Task.isCancelled`, are unchanged.

*CPU temperature:* when macOS doesn't provide one, which is always the case on Apple
Silicon today, **no temperature is shown at all**. The Overview's CPU card shows
**Thermal State** instead (Nominal / Fair / Serious / Critical). That is macOS's public
heat signal, a different real measurement, labeled as such. If a temperature ever
becomes available, it is shown instead.

*Information page* (System › Information; `SystemInfoService`, `MacOSUpdateService`).
It refreshes when opened, and **Refresh** forces a refresh.

| Area | Shows | Source |
|---|---|---|
| macOS | version, build, release name, kernel, uptime, last boot | `ProcessInfo`, `sysctl`; the release name comes from Apple's security page (macOS 27 = "Golden Gate"), because this macOS doesn't record its own name |
| This Mac | model name, identifier, chip, cores, memory, GPU, architecture, storage, serial number | I/O Registry and `sysctl`. The serial number is **masked until you click Show** |
| Software Update | installed version, **latest for this Mac** and **latest released by Apple** (with dates), update available or not | Apple's software update feed `gdmf.apple.com/v2/pmv`, which lists the exact board IDs each release supports, so compatibility is never assumed |
| Security and Fixes | priority (Critical / High / Medium / Low) **with the reason**, issues fixed per newer release grouped by impact, CVE IDs, whether the installed version is affected, "actively exploited" warnings, link to Apple's notes | Apple Security Releases, `support.apple.com/en-us/100100`, plus the linked page for each release |

- **Privacy:** both online lists are public and downloaded in full; filtering happens
  on the Mac, so nothing identifying this Mac is sent. Results are cached for 12 h in
  `~/Library/Caches`. If you're offline, local information still shows, with a notice.
- **Verified on this Mac:**
  - Model, chip, cores and memory match `system_profiler`.
  - A newer release is reported as available only when Apple's feed lists this Mac's
    board ID.
  - A release fixing both code-execution and kernel/root privilege issues is rated
    Critical, and the page says why.
- **Not shown on purpose:**
  - **Apple Account email:** macOS has no supported API for reading it. The only route
    is another app's private preference files, so the field is hidden.
  - **Bug fixes and known issues:** Apple doesn't publish them in a reliable
    machine-readable form, so the page points to Software Update's notes instead.

*Power page* (System › Power; `PowerService`). None of these actions need admin rights:

| Action | How | Confirmation |
|---|---|---|
| Restart | Apple Event `kAERestart` to `loginwindow`, the same as the Apple menu. Apps are asked to quit and can cancel | Yes |
| Shut Down | Apple Event `kAEShutDown` to `loginwindow` | Yes |
| Sleep | `pmset sleepnow`, falling back to `kAESleep` | No |
| Lock Screen | `SACLockScreenImmediate` from macOS's login framework | No |

- **New permission text:** the first Restart or Shut Down may trigger macOS's
  Automation prompt ("control loginwindow"). The Info.plist now includes
  `NSAppleEventsUsageDescription` to explain it. No new entitlements.
- ⚠️ **Lock Screen uses a private, undocumented function.** It is the one the Apple
  menu itself uses. There is no public API that locks immediately: display sleep only
  locks after the "Require password" delay, (for example 5 minutes). The function is
  looked up at runtime, and the button hides itself if a future macOS removes it.
- *Not run during development:* Restart, Shut Down, Sleep and Lock would interrupt the
  session. Tests check the action setup, the confirmation rules, the error messages,
  and that the lock function exists, without calling it.

**Units.** RAM uses binary GB (1024³), like Activity Monitor. Disk uses decimal GB
(1000³), like Finder. Network speed is MB/s or Mbps, chosen in Settings.

---

## Limitations to know about

- **Code signing:** the app is signed ad-hoc. That's fine on your own Mac. To share it
  with others you'd need an Apple Developer ID certificate and notarization. Otherwise
  Gatekeeper will block it on their machines (right-click → Open works around this).
- **Sandboxing:** the app is **not sandboxed**, and no claim of sandbox compatibility is
  made. It reads system statistics and your cache folders, which a sandbox would block.
  Some folders (the Trash, Safari's cache) need *Full Disk Access*. Without it, the app
  says so and skips them; it never tries to work around macOS.
- **No root or admin rights:** other users' and system processes aren't shown in Memory
  by App, and macOS gives apps network counters rounded to 1 KB that wrap every 4 GB.
  Both are explained on the pages concerned.
- **Per-core labels:** the "Efficiency cores come first" ordering holds on M1–M4. If a
  future chip reports cores in a different order, the E/P labels could be wrong (the
  percentages would still be right).
- **Temperature:** Apple Silicon temperature sensors need private APIs, so temperature
  isn't shown. The battery's temperature is also hidden from apps on macOS 27.
- **Launch at login** needs the packaged `.app` and works best from `/Applications`.
  Because the app is ad-hoc signed, macOS may ask you to approve it under Login Items.
  *Not tested live:* switching it on would change your login items, so I left that to
  you.
- **Background pause:** while the window is hidden, minimized, on another Space or
  fully covered, monitoring pauses. Charts show a gap for that time. The first values
  after returning are averages over the time spent hidden.
- **`swift run` vs `.app`:** both work. Launch at login and the app icon need the
  packaged `.app`.

## Release checklist

1. Run the tests:
   ```bash
   swift test
   ```
2. Build and package the app:
   ```bash
   Scripts/build.sh release
   ```
3. Optional: check every page in light and dark mode. The screenshots are saved to
   `./snapshots`:
   ```bash
   Scripts/snapshot.sh
   ```
4. Install it by dragging `build/MacMonitor.app` into `/Applications`, or:
   ```bash
   cp -R build/MacMonitor.app /Applications/
   ```

## Safety principles for the Cleaner (Phases 8–10)

These are fixed by design, and Settings shows them as non-editable:

- Never delete automatically, on startup, or on a schedule.
- Scan → report → review → you select → confirmation screen → act on approved items only.
- Move to Trash by default. Emptying the Trash needs a separate confirmation.
- Only recognized directories. Reject symlinks and path traversal, and re-check every
  path just before acting.
- Never `sudo` and never `rm -rf`.
