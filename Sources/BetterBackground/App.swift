import AppKit
import SwiftUI

@main
struct BetterBackgroundApp: App {
    init() {
        // Makes the window come to the front even when launched as a bare binary.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("BetterBackground") {
            ContentView()
                .frame(minWidth: 960, minHeight: 600)
        }
    }
}
