import SwiftUI
import AppKit

/// Entry point of the application.
///
/// `@main` tells Swift that this type starts the program. Because we use the
/// SwiftUI `App` protocol, we never write a `main.swift` or an Xcode storyboard:
/// everything is plain Swift code, which is why the project builds with only
/// the Command Line Tools.
@main
struct MacMonitorApp: App {
    /// Bridges a classic AppKit delegate into the SwiftUI lifecycle.
    /// We need it so the app behaves like a normal Dock app even when it is
    /// launched as a bare executable via `swift run` (no .app bundle).
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// One shared view model for the whole window. `@State` keeps it alive
    /// for the lifetime of the app.
    @ViewState private var viewModel = DashboardViewModel()

    var body: some Scene {
        WindowGroup("MacMonitor") {
            ContentView()
                .environment(viewModel)
                .frame(minWidth: 880, minHeight: 580)
        }
        .defaultSize(width: 1120, height: 740)
        .windowResizability(.contentMinSize)
        .commands {
            // Remove "New Window" – a single dashboard window is enough.
            CommandGroup(replacing: .newItem) {}
            // ⌘, opens the Settings page (the standard Mac shortcut).
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { viewModel.selectedPage = .settings }
                    .keyboardShortcut(",")
            }
            // Go menu: ⌘1 Overview … ⌘9 Power (⌘, opens Settings).
            CommandMenu("Go") {
                ForEach(Array(SidebarItem.allCases.enumerated()), id: \.element) { index, page in
                    if index < 9 {
                        Button(page.title) { viewModel.selectedPage = page }
                            .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    } else {
                        Button(page.title) { viewModel.selectedPage = page }
                    }
                }
            }
        }
    }
}

/// Classic AppKit delegate used for a few app-level behaviors.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // When started from Terminal without a bundle, macOS treats the
        // process as a background tool. These two lines give it a Dock icon,
        // a menu bar and bring its window to the front.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()

        // Apply the saved Light / Dark / System preference on launch.
        AppearanceMode.current.apply()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
