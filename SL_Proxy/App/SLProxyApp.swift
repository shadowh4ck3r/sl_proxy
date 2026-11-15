import SwiftUI

@main
struct SLProxyApp: App {
    @StateObject private var settings: SettingsStore
    @StateObject private var nodes: NodeStore
    @StateObject private var tunnel: TunnelController
    @StateObject private var backup: ICloudBackupStore

    init() {
        let settings = SettingsStore()
        let nodes = NodeStore()
        _settings = StateObject(wrappedValue: settings)
        _nodes = StateObject(wrappedValue: nodes)
        _tunnel = StateObject(wrappedValue: TunnelController(nodes: nodes, settings: settings))
        // Connects to NSUbiquitousKeyValueStore and starts mirroring servers, subscriptions,
        // rules and options into the user's iCloud account (Advanced & Pro > iCloud Backup).
        _backup = StateObject(wrappedValue: ICloudBackupStore(nodes: nodes, settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(nodes)
                .environmentObject(tunnel)
                .environmentObject(backup)
                // Apply the user's theme choice (system / light / dark) to the whole app.
                .preferredColorScheme(settings.value.colorScheme.colorScheme)
                // Apply the user's App Font choice (System / Mono / Sketch) to the whole app.
                .appFont(settings.value.fontStyle)
                .onOpenURL { url in
                    // Share links opened from other apps (ss://, vmess://, ...).
                    nodes.toast = nodes.importText(url.absoluteString).summary
                }
        }
    }
}
