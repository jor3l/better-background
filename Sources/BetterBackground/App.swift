import AppKit
import SwiftUI

@main
struct BetterBackgroundApp: App {
    @StateObject private var updater = AppUpdater()

    init() {
        // Makes the window come to the front even when launched as a bare binary.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("BetterBackground") {
            ContentView()
                .frame(minWidth: 1000, minHeight: 600)
        }
        .commands { UpdateCommands(updater: updater) }

        Settings {
            UpdateSettingsView(updater: updater)
                .frame(width: 460)
        }
    }
}
