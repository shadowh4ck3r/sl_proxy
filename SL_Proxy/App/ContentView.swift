import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var nodes: NodeStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var tunnel: TunnelController

    /// Appearance Settings > "Show only in Home Tab" off: the other tabs get a floating Connect
    /// button. Read from the global `SettingsStore`, so flipping the toggle updates every tab at once.
    private var showsConnectButtonEverywhere: Bool {
        !settings.value.showButtonOnlyInHomeTab
    }

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "bolt.shield") }
            ConfigsView()
                .floatingConnectButton(visible: showsConnectButtonEverywhere)
                .tabItem { Label("Configs", systemImage: "server.rack") }
            RulesView()
                .floatingConnectButton(visible: showsConnectButtonEverywhere)
                .tabItem { Label("Rules", systemImage: "arrow.triangle.branch") }
            MarketView()
                .floatingConnectButton(visible: showsConnectButtonEverywhere)
                .tabItem { Label("Proxies", systemImage: "globe") }
            SettingsView()
                .floatingConnectButton(visible: showsConnectButtonEverywhere)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(Brand.orange)
        .overlay(alignment: .top) {
            if let toast = nodes.toast {
                ToastView(text: toast)
                    .id(toast)
                    .task {
                        try? await Task.sleep(for: .seconds(2.5))
                        if nodes.toast == toast { nodes.toast = nil }
                    }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: nodes.toast)
        // A running tunnel picks up node and settings changes automatically.
        .onChange(of: nodes.activeNodeID) { _ in tunnel.applyChanges() }
        .onChange(of: settings.value) { _ in tunnel.applyChanges() }
    }
}

private struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote.weight(.medium))
            .lineLimit(2)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Brand.gradient, lineWidth: 1).opacity(0.7))
            .shadow(color: Brand.orange.opacity(0.2), radius: 12, y: 6)
            .padding(.top, 8)
            .padding(.horizontal)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}
