import SwiftUI

/// Home tab. Its layout follows the Appearance Settings stored in the global `SettingsStore`:
/// - `navigationStyle` switches every card between the flat Erosion surface and the Katzy glass card,
/// - `connectionButtonSize` sets the diameter of the Connect ring,
/// - `fixedButtonPosition` docks the button (with a Ping chip under it) at the bottom-left above the
///   tab bar, V2Box style, instead of scrolling with the content.
///
/// `SettingsStore` is an `ObservableObject`, so a change made in Appearance Settings re-renders this
/// view immediately. `showButtonOnlyInHomeTab` is handled by `ContentView`, which adds a floating
/// Connect button to the other tabs when it is off.
struct HomeView: View {
    @EnvironmentObject private var tunnel: TunnelController
    @EnvironmentObject private var nodes: NodeStore
    @EnvironmentObject private var settings: SettingsStore
    @State private var showNodePicker = false
    @StateObject private var exitIP = ExitIPStore()
    @StateObject private var banners = BannerStore()
    @EnvironmentObject private var ota: OTAManager
    /// The user's pick from Settings > Appearance > Home Screen Style; empty until they choose.
    @AppStorage(HomeLayoutStyle.storageKey) private var storedLayout = ""

    private static let layoutAnimation = Animation.spring(response: 0.4, dampingFraction: 0.8)

    private var style: NavigationStyle { settings.value.navigationStyle }
    private var buttonSize: ConnectionButtonSize { settings.value.connectionButtonSize }
    private var isButtonFixed: Bool { settings.value.fixedButtonPosition }
    private var layout: HomeLayoutStyle {
        HomeLayoutStyle.resolve(stored: storedLayout, otaDefault: ota.stringFlag("default_home_layout"))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Brand.background
                switch layout {
                case .classic:
                    classicContent
                case .tactical:
                    TacticalHomeView(showNodePicker: $showNodePicker, top: topSection, bottom: bottomSection)
                case .telemetry:
                    TelemetryHomeView(showNodePicker: $showNodePicker, top: topSection, bottom: bottomSection)
                case .terminal:
                    TerminalHomeView(exitIP: exitIP, top: topSection, bottom: bottomSection)
                }
            }
            .animation(Self.layoutAnimation, value: buttonSize)
            .animation(Self.layoutAnimation, value: isButtonFixed)
            .animation(.easeInOut(duration: 0.25), value: style)
            .toolbar {
                ToolbarItem(placement: .principal) { BrandLogo(height: 22) }
            }
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showNodePicker) { NodePickerSheet() }
            .task { await banners.refresh() }
            // Flag and masked exit IP of the running connection; cleared on disconnect.
            .task(id: "\(tunnel.isConnected)-\(nodes.activeNodeID?.uuidString ?? "")") {
                if tunnel.isConnected {
                    try? await Task.sleep(for: .seconds(2))
                    await exitIP.refresh(endpoint: tunnel.proxyEndpoint)
                } else {
                    exitIP.clear()
                }
            }
        }
    }

    // MARK: - Layouts

    /// OTA `home.top` components plus the banner ad, shared by every layout.
    private var topSection: AnyView {
        AnyView(VStack(spacing: 18) {
            DynamicOTAView(placement: "home.top")
            if !banners.banners.isEmpty {
                BannerAdCard(banners: banners.banners, style: style)
            }
        })
    }

    /// OTA `home.bottom` components (for example the Smart routing toggle).
    private var bottomSection: AnyView {
        AnyView(DynamicOTAView(placement: "home.bottom"))
    }

    /// The original Home layout ("classic"), unchanged apart from the OTA-gated chart card.
    private var classicContent: some View {
        ScrollView {
                    VStack(spacing: 18) {
                        DynamicOTAView(placement: "home.top")
                        if !banners.banners.isEmpty {
                            BannerAdCard(banners: banners.banners, style: style)
                        }
                        if isButtonFixed {
                            statusPill
                        } else {
                            connectCard
                        }
                        LocalProxyCard(endpoint: tunnel.proxyEndpoint,
                                       isRunning: tunnel.isConnected,
                                       passthroughActive: tunnel.passthroughActive) {
                            UIPasteboard.general.string = tunnel.proxyEndpoint
                            nodes.toast = "Proxy address copied"
                        }
                        CellularCard(verifier: tunnel.verifier, budget: tunnel.budget, style: style)
                        nodeCard
                        modeCard
                        // Moved to Settings. The OTA flag `hide_home_chart` (default true) decides:
                        // set it to false in ui.json "flags" to show the chart here again.
                        if !ota.hidesHomeChart {
                            TrafficCard(traffic: tunnel.traffic)
                        }
                        if let error = tunnel.lastError {
                            errorCard(error)
                        }
                        DynamicOTAView(placement: "home.bottom")
                    }
                    .padding()
                }
    }

    // MARK: - Connect button

    /// The one Connect ring on Home; lives in `connectCard` or in `fixedConnectDock` depending on
    /// the Fixed Button Position setting.
    private var connectRing: some View {
        ConnectRing(
            size: buttonSize,
            style: style,
            isConnected: tunnel.isConnected,
            isTransitioning: tunnel.isTransitioning
        ) {
            tunnel.toggle()
        }
        .disabled(tunnel.isBusy)
    }

    /// One line of status shown instead of the big card while the Connect button floats (Fixed
    /// Button Position on): state, uptime and the exit flag with a masked IP.
    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tunnel.isConnected ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text(LocalizedStringKey(tunnel.statusText))
                .font(.footnote.weight(.semibold))
            if let since = tunnel.connectedSince {
                Text(since, style: .timer)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if tunnel.isConnected, let info = exitIP.info {
                Text("\(info.flag) \(info.maskedIP)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Brand.gradient, lineWidth: 1).opacity(0.5))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Cards

    private var connectCard: some View {
        VStack(spacing: 16) {
            if !isButtonFixed {
                connectRing
                    .padding(.top, 6)
            }

            Text(LocalizedStringKey(tunnel.statusText))
                .font(.title3.weight(.semibold))

            if tunnel.isConnected, let info = exitIP.info {
                Text("\(info.flag) \(info.maskedIP)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Exit \(info.country)")
            }

            if tunnel.backgroundKeepAliveActive {
                Label("Keeps running in background", systemImage: "waveform")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Brand.gold)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Brand.gold.opacity(0.5), lineWidth: 1))
            }

            if let since = tunnel.connectedSince {
                Text(since, style: .timer)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Text(nodes.activeNode == nil ? "Import a server in Configs to get started" : "Tap to connect")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .navigationStyleCard(style)
    }

    private var nodeCard: some View {
        Button { showNodePicker = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "server.rack")
                    .font(.title2)
                    .foregroundStyle(Brand.gradient)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 4) {
                    if let node = nodes.activeNode {
                        Text(node.name).font(.headline).lineLimit(1)
                        HStack(spacing: 6) {
                            KindBadge(kind: node.kind)
                            Text(node.displayServer.masked)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } else {
                        Text("No server selected").font(.headline)
                        Text("Choose or import a server").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let node = nodes.activeNode {
                    LatencyPill(latency: node.latencyMs, isTesting: nodes.testingIDs.contains(node.id))
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .navigationStyleCard(style, cornerRadius: 18)
        }
        .buttonStyle(.plain)
    }

    private var modeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Routing mode", selection: $settings.value.routingMode) {
                ForEach(RoutingMode.allCases) { mode in
                    Text(LocalizedStringKey(mode.title)).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text(settings.value.routingMode.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .navigationStyleCard(style, cornerRadius: 18)
    }

    private func errorCard(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(error)
                .font(.footnote)
            Spacer(minLength: 0)
            Button { tunnel.lastError = nil } label: {
                Image(systemName: "xmark").font(.caption.weight(.bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .navigationStyleCard(style, cornerRadius: 16)
    }
}

/// Power button with a gradient ring; spins while connecting. The diameter comes from the
/// Connection Button Size chosen in Appearance Settings.
struct ConnectRing: View {
    var size: ConnectionButtonSize = .medium
    /// Erosion draws the vintage wooden switch, Katzy the glass ring.
    var style: NavigationStyle = .katzy
    let isConnected: Bool
    let isTransitioning: Bool
    let action: () -> Void
    @State private var spinning = false

    private var diameter: CGFloat { size.diameter }
    private var lineWidth: CGFloat { size.ringLineWidth }

    /// Radius of the soft gold/orange glow; scales with the button so a small button gets a small
    /// halo instead of a blob that spills over the neighbouring cards.
    private var glowRadius: CGFloat {
        max(8, diameter * 0.16)
    }

    private var glowOpacity: Double {
        isConnected ? 0.45 : 0.12
    }

    @ViewBuilder
    var body: some View {
        if style.usesGlassmorphism {
            ringBody
        } else {
            VintageConnectSwitch(height: diameter, isOn: isConnected, isBusy: isTransitioning, action: action)
        }
    }

    private var ringBody: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                Circle()
                    .strokeBorder(Brand.gradient, lineWidth: lineWidth)
                    .opacity(isConnected ? 1 : 0.3)
                if isTransitioning {
                    Circle()
                        .trim(from: 0, to: 0.28)
                        .stroke(Brand.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .padding(lineWidth / 2)
                        .rotationEffect(.degrees(spinning ? 360 : 0))
                        .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spinning)
                        .onAppear { spinning = true }
                        .onDisappear { spinning = false }
                }
                Image(systemName: "power")
                    .font(.system(size: diameter * 0.31, weight: .semibold))
                    .foregroundStyle(isConnected ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(.secondary))
            }
            .frame(width: diameter, height: diameter)
            .shadow(color: Brand.gold.opacity(glowOpacity), radius: glowRadius)
            .shadow(color: Brand.orange.opacity(glowOpacity), radius: glowRadius)
            .animation(.easeInOut(duration: 0.3), value: isConnected)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: diameter)
        }
        .buttonStyle(.plain)
    }
}

/// Ping chip shown under the Connect button (V2Box style). Tapping it tests the active server and
/// shows the result as a colour-coded latency: the real round trip through the proxy while the
/// core runs, the TCP connect time otherwise (see `NodeStore.testLatency`).
struct PingChip: View {
    @EnvironmentObject private var nodes: NodeStore

    private var node: ProxyNode? { nodes.activeNode }

    private var isTesting: Bool {
        guard let node else { return false }
        return nodes.testingIDs.contains(node.id)
    }

    private var status: LatencyStatus {
        LatencyStatus(latency: node?.latencyMs, isTesting: isTesting)
    }

    private var text: String {
        switch status {
        case .untested: return "Ping"
        case .testing: return "Testing"
        case .timeout: return "timeout"
        default: return "\(node?.latencyMs ?? 0) ms"
        }
    }

    var body: some View {
        Button {
            guard let node else { return }
            Task { await nodes.testLatency(node) }
        } label: {
            HStack(spacing: 6) {
                switch status {
                case .testing:
                    ProgressView().controlSize(.mini).tint(.white)
                case .untested:
                    Image(systemName: "waveform.path.ecg")
                        .font(.caption2.weight(.bold))
                default:
                    Circle().fill(status.color).frame(width: 7, height: 7)
                }
                Text(text)
                    .font(.caption.monospacedDigit().weight(.semibold))
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.black.opacity(0.78), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(node == nil || isTesting)
        .accessibilityLabel(status == .untested ? "Ping the active server" : "Latency \(text), \(status.title)")
    }
}

/// Connect button with the Ping chip under it, pinned at the bottom-left above the tab bar on the
/// non-Home tabs while Appearance Settings > "Show only in Home Tab" is off. It is only as big as
/// the chosen Connection Button Size, so it no longer takes a full-width bar.
struct FloatingConnectButton: View {
    @EnvironmentObject private var tunnel: TunnelController
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ConnectRing(
                size: settings.value.connectionButtonSize,
                style: settings.value.navigationStyle,
                isConnected: tunnel.isConnected,
                isTransitioning: tunnel.isTransitioning
            ) {
                tunnel.toggle()
            }
            .disabled(tunnel.isBusy)
            PingChip()
        }
        .padding(.leading, 16)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Connect button, \(tunnel.statusText)")
    }
}

extension View {
    /// Pins `FloatingConnectButton` at the bottom-left above the tab bar when `visible` is true
    /// (Appearance Settings > "Show only in Home Tab" off). The toggle animates it in and out.
    func floatingConnectButton(visible: Bool) -> some View {
        safeAreaInset(edge: .bottom, alignment: .leading, spacing: 0) {
            if visible {
                FloatingConnectButton()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: visible)
    }
}
