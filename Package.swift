// swift-tools-version: 6.0
// The line above is required: it tells Swift Package Manager which manifest
// format this file uses. 6.0 enables the Swift 6 language mode (strict
// concurrency checking), which your Swift 6.4 toolchain supports.

import PackageDescription

let package = Package(
    name: "MacMonitor",
    // macOS 14 (Sonoma) is the minimum because we use the @Observable macro
    // and Swift Charts' SectorMark. Your machine runs macOS 27, so this is fine.
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // A single executable target. SwiftPM compiles every .swift file in
        // Sources/MacMonitor (including subfolders) into one binary.
        .executableTarget(
            name: "MacMonitor",
            path: "Sources/MacMonitor"
        ),
        // Unit tests, run with `swift test`. They use Swift Testing
        // (`import Testing`), which ships with the Command Line Tools.
        // (XCTest does not – it comes only with full Xcode.)
        .testTarget(
            name: "MacMonitorTests",
            dependencies: ["MacMonitor"],
            path: "Tests/MacMonitorTests",
            swiftSettings: [
                // Command-Line-Tools workaround: the `@Test` / `#expect` macro
                // plugin is installed here, but SwiftPM doesn't pass it to the
                // compiler unless full Xcode is present. This flag tells the
                // compiler where to find it. It only affects the test target.
                .unsafeFlags(["-plugin-path",
                              "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"])
            ]
        )
    ]
)
