import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var nodes: NodeStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var tunnel: TunnelController
    /// Over-the-air UI and logic from sailorsloot.xyz (Core/OTAManager.swift). Created next to the
    /// three stores it bridges to and started with them in `.task` below.
    @StateObject private var ota = OTAManager()

    private enum AppTab: Hashable { case home, configs, rules, proxies, settings }

    @State private var tab: AppTab = .home

    /// Whether the draggable Connect button floats over the current tab. On Home it floats when
    /// Fixed Button Position is on (otherwise the button lives in the Home card); on the other tabs
    /// it floats unless "Show only in Home Tab" is on.
    private var connectButtonVisible: Bool {
        tab == .home ? settings.value.fixedButtonPosition : !settings.value.showButtonOnlyInHomeTab
    }

    var body: some View {
        TabView(selection: $tab) {
            HomeView()
                .tabItem { Label("Home", systemImage: "bolt.shield") }
                .tag(AppTab.home)
            ConfigsView()
                .tabItem { Label("Configs", systemImage: "server.rack") }
                .tag(AppTab.configs)
            RulesView()
                .tabItem { Label("Rules", systemImage: "arrow.triangle.branch") }
                .tag(AppTab.rules)
            MarketView()
                .tabItem { Label("Proxies", systemImage: "globe") }
                .tag(AppTab.proxies)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .tint(Brand.orange)
        .overlay { DraggableConnectOverlay(visible: connectButtonVisible) }
        .overlay(alignment: .top) {
            if let toast = nodes.toast {
                ToastView(text: toast)
                    .id(toast)
                    .onTapGesture { nodes.toast = nil }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: nodes.toast)
        // A message left over from before the app was in the background is stale: drop it.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            nodes.toast = nil
        }
        // A running tunnel picks up node and settings changes automatically.
        .onChange(of: nodes.activeNodeID) { _ in tunnel.applyChanges() }
        .onChange(of: settings.value) { _ in tunnel.applyChanges() }
        // Announcement modals from ui.json; the manager reaches every screen through the environment.
        .otaModals(ota)
        .environmentObject(ota)
        // Loads the cached (or bundled) bundle, then checks the server; later checks follow
        // UIApplication.didBecomeActiveNotification inside the manager.
        .task { ota.start(nodes: nodes, settings: settings, tunnel: tunnel) }
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
