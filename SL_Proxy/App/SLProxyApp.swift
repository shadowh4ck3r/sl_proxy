import SwiftUI

@main
struct SLProxyApp: App {
    @StateObject private var settings: SettingsStore
    @StateObject private var nodes: NodeStore
    @StateObject private var tunnel: TunnelController
    @StateObject private var backup: ICloudBackupStore
    @StateObject private var account: SLAccountStore
    @StateObject private var market: ProxyMarketStore
    @StateObject private var language = LanguageStore()
    @State private var showSplash = true

    init() {
        let settings = SettingsStore()
        let nodes = NodeStore()
        let tunnel = TunnelController(nodes: nodes, settings: settings)
        let account = SLAccountStore()
        _settings = StateObject(wrappedValue: settings)
        _nodes = StateObject(wrappedValue: nodes)
        _tunnel = StateObject(wrappedValue: tunnel)
        _account = StateObject(wrappedValue: account)
        _market = StateObject(wrappedValue: ProxyMarketStore(account: account, nodes: nodes, tunnel: tunnel))
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
                .environmentObject(account)
                .environmentObject(market)
                .environmentObject(language)
                // In-app language: every Text("...") re-resolves from <code>.lproj at once.
                .environment(\.locale, language.locale)
                .environment(\.layoutDirection, language.layoutDirection)
                .overlay {
                    if showSplash {
                        SplashView()
                            .transition(.opacity)
                    }
                }
                .task {
                    try? await Task.sleep(for: .seconds(1.4))
                    withAnimation(.easeOut(duration: 0.4)) { showSplash = false }
                }
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
