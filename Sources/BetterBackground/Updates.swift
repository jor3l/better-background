import Combine
import Sparkle
import SwiftUI

/// Owns the Sparkle updater. The feed URL and public key come from Info.plist
/// (SUFeedURL, SUPublicEDKey); updates are the .dmg files on GitHub Releases.
final class AppUpdater: ObservableObject {
    private let controller: SPUStandardUpdaterController
    private var observations: [NSKeyValueObservation] = []

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var lastCheck: Date?

    var updater: SPUUpdater { controller.updater }

    /// False when running a bare binary (e.g. `swift run`), where there is no app bundle to replace.
    let isAvailable: Bool

    init() {
        isAvailable = Bundle.main.bundleURL.pathExtension == "app"
            && Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        controller = SPUStandardUpdaterController(
            startingUpdater: isAvailable, updaterDelegate: nil, userDriverDelegate: nil)
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                DispatchQueue.main.async { self?.canCheckForUpdates = updater.canCheckForUpdates }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.initial, .new]) { [weak self] updater, _ in
                DispatchQueue.main.async { self?.lastCheck = updater.lastUpdateCheckDate }
            },
        ]
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    var automaticallyChecks: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { objectWillChange.send(); updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloads: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set { objectWillChange.send(); updater.automaticallyDownloadsUpdates = newValue }
    }

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

/// "Check for Updates…" in the app menu, under "About BetterBackground".
struct UpdateCommands: Commands {
    @ObservedObject var updater: AppUpdater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.isAvailable || !updater.canCheckForUpdates)
        }
    }
}

/// The "Updates" section of the Settings window.
struct UpdateSettingsView: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        Form {
            Section {
                LabeledContent("Current version", value: updater.version)
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { updater.automaticallyChecks },
                    set: { updater.automaticallyChecks = $0 }))
                Toggle("Download and install updates automatically", isOn: Binding(
                    get: { updater.automaticallyDownloads },
                    set: { updater.automaticallyDownloads = $0 }))
                    .disabled(!updater.automaticallyChecks)
                HStack {
                    Button("Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.isAvailable || !updater.canCheckForUpdates)
                    Spacer()
                    if let last = updater.lastCheck {
                        Text("Last checked \(last.formatted(.relative(presentation: .named)))")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
            } header: {
                Text("Updates")
            } footer: {
                if !updater.isAvailable {
                    Text("Updates are only available in the packaged app.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(!updater.isAvailable)
    }
}
