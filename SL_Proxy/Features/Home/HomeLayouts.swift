import SwiftUI

/// The selectable Home screen layouts (Settings > Appearance > Home Screen Style).
///
/// `classic` is the original `HomeView` content, untouched. The other three share the same state
/// (`TunnelController`, `NodeStore`, `SettingsStore`, `ProfileVerifier`, `TrafficMonitor`) and the
/// gold / amber brand palette. Every layout keeps the `SL>_` image logo in the navigation header
/// (`HomeView` puts `BrandLogo` in the toolbar for all of them).
enum HomeLayoutStyle: String, CaseIterable, Identifiable {
    case classic, tactical, telemetry, terminal

    /// `@AppStorage` key holding the user's pick. Empty until the user chooses one.
    static let storageKey = "homeLayoutStyle"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: return "Classic"
        case .tactical: return "Tactical Dashboard"
        case .telemetry: return "Clean Telemetry"
        case .terminal: return "Matrix Terminal"
        }
    }

    /// The user's pick, else the OTA `default_home_layout`, else Classic.
    static func resolve(stored: String, otaDefault: String?) -> HomeLayoutStyle {
        if let style = HomeLayoutStyle(rawValue: stored) { return style }
        if let raw = otaDefault, let style = HomeLayoutStyle(rawValue: raw) { return style }
        return .classic
    }
}

// MARK: - Shared pieces

private extension View {
    /// Compact brand card used by the Tactical and Telemetry layouts.
    func bentoCard(cornerRadius: CGFloat = 18) -> some View {
        self
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Brand.gradient, lineWidth: 1)
                    .opacity(0.5)
            )
    }
}

/// `Rule / Global / Direct` segmented control bound to the routing mode.
private struct HomeModePicker: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Picker("Routing mode", selection: $settings.value.routingMode) {
            ForEach(RoutingMode.allCases) { mode in
                Text(LocalizedStringKey(mode.title)).tag(mode)
            }
        }
        .pickerStyle(.segmented)
    }
}

/// Active server row: name, protocol badge, masked address, latency; taps open the node picker.
private struct ActiveServerRow: View {
    @EnvironmentObject private var nodes: NodeStore
    @Binding var showNodePicker: Bool

    var body: some View {
        Button { showNodePicker = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.title3)
                    .foregroundStyle(Brand.gradient)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    if let node = nodes.activeNode {
                        Text(node.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        HStack(spacing: 6) {
                            KindBadge(kind: node.kind)
                            Text(node.displayServer.masked)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } else {
                        Text("No server selected").font(.subheadline.weight(.semibold))
                        Text("Choose or import a server").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if let node = nodes.activeNode {
                    LatencyPill(latency: node.latencyMs, isTesting: nodes.testingIDs.contains(node.id))
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .bentoCard()
        }
        .buttonStyle(.plain)
    }
}

/// The physical ON / OFF switch (the vintage wooden toggle) with its caption.
private struct PowerSwitch: View {
    @EnvironmentObject private var tunnel: TunnelController
    var size: ConnectionButtonSize = .medium

    var body: some View {
        VStack(spacing: 8) {
            ConnectRing(
                size: size,
                style: .erosion,
                isConnected: tunnel.isConnected,
                isTransitioning: tunnel.isTransitioning
            ) {
                tunnel.toggle()
            }
            .disabled(tunnel.isBusy)
            Text(LocalizedStringKey(tunnel.isConnected ? "ON" : "OFF"))
                .font(.caption.weight(.bold).monospaced())
                .foregroundStyle(tunnel.isConnected ? Brand.gold : Color.secondary)
        }
    }
}

private struct HomeErrorBanner: View {
    @EnvironmentObject private var tunnel: TunnelController

    var body: some View {
        if let error = tunnel.lastError {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(error).font(.footnote)
                Spacer(minLength: 0)
                Button { tunnel.lastError = nil } label: {
                    Image(systemName: "xmark").font(.caption.weight(.bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .bentoCard(cornerRadius: 16)
        }
    }
}

// MARK: - Tactical Dashboard

/// Two-column bento cards (Local proxy, Cellular profile), the Active Server row, the
/// Rule / Global / Direct control and the physical ON / OFF switch.
struct TacticalHomeView: View {
    @EnvironmentObject private var tunnel: TunnelController
    @EnvironmentObject private var nodes: NodeStore
    @Binding var showNodePicker: Bool
    /// OTA `home.top` components and the banner ad.
    let top: AnyView
    /// OTA `home.bottom` components.
    let bottom: AnyView

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                top
                HStack(alignment: .top, spacing: 12) {
                    localProxyCard
                    TacticalCellularCard(verifier: tunnel.verifier)
                }
                ActiveServerRow(showNodePicker: $showNodePicker)
                HomeModePicker()
                PowerSwitch()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 6)
                HomeErrorBanner()
                bottom
            }
            .padding()
        }
    }

    private var localProxyCard: some View {
        Button {
            UIPasteboard.general.string = tunnel.proxyEndpoint
            nodes.toast = "Proxy address copied"
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.title3)
                    .foregroundStyle(tunnel.isConnected ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(Color.secondary))
                Text("Local proxy").font(.subheadline.weight(.semibold))
                Text(tunnel.proxyEndpoint)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(LocalizedStringKey(caption))
                    .font(.caption2)
                    .foregroundStyle(tunnel.isConnected ? Brand.gold : Color.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
            .bentoCard()
        }
        .buttonStyle(.plain)
    }

    private var caption: String {
        if tunnel.isConnected { return "Listening" }
        if tunnel.passthroughActive { return "DIRECT" }
        return "Idle"
    }
}

private struct TacticalCellularCard: View {
    @ObservedObject var verifier: ProfileVerifier

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "simcard")
                .font(.title3)
                .foregroundStyle(Brand.gradient)
            Text("Cellular profile").font(.subheadline.weight(.semibold))
            ProfileVerifiedBadge(state: verifier.state)
        }
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
        .bentoCard()
    }
}

// MARK: - Clean Telemetry

/// Single column: logo, status pill, compact server card, stacked live metrics and a bottom
/// control bar with the routing control and the ON / OFF switch.
struct TelemetryHomeView: View {
    @EnvironmentObject private var tunnel: TunnelController
    @Binding var showNodePicker: Bool
    /// OTA `home.top` components and the banner ad.
    let top: AnyView
    /// OTA `home.bottom` components.
    let bottom: AnyView

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    top
                    BrandLogo(height: 44)
                    statusPill
                    ActiveServerRow(showNodePicker: $showNodePicker)
                    TelemetryMetrics(traffic: tunnel.traffic)
                    HomeErrorBanner()
                    bottom
                }
                .padding()
            }
            controlBar
        }
    }

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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Brand.gradient, lineWidth: 1).opacity(0.5))
    }

    private var controlBar: some View {
        HStack(spacing: 14) {
            HomeModePicker()
            PowerSwitch(size: .small)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
    }
}

private struct TelemetryMetrics: View {
    @ObservedObject var traffic: TrafficMonitor
    @EnvironmentObject private var nodes: NodeStore

    var body: some View {
        VStack(spacing: 0) {
            row("Download", traffic.downloadSpeedText, icon: "arrow.down.circle.fill")
            Divider()
            row("Upload", traffic.uploadSpeedText, icon: "arrow.up.circle.fill")
            Divider()
            row("Latency", latencyText, icon: "waveform.path.ecg")
        }
        .bentoCard()
    }

    private var latencyText: String {
        guard let ms = nodes.activeNode?.latencyMs, ms > 0 else { return "--" }
        return "\(ms) ms"
    }

    private func row(_ title: String, _ value: String, icon: String) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(Brand.gradient)
                .frame(width: 28)
            Text(LocalizedStringKey(title))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.title3.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.vertical, 10)
    }
}

// MARK: - Matrix Terminal

/// Developer-style monospace view. Keys are cyan / purple, `CONNECTED`, `[OK]` and
/// `VERIFIED & ACTIVE` bright green, IP addresses blue, and the lower half scrolls the live
/// sing-box log. Terminal tokens stay in English on purpose.
struct TerminalHomeView: View {
    @EnvironmentObject private var tunnel: TunnelController
    @EnvironmentObject private var nodes: NodeStore
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var exitIP: ExitIPStore
    /// OTA `home.top` components and the banner ad.
    let top: AnyView
    /// OTA `home.bottom` components.
    let bottom: AnyView

    @State private var logLines: [TunnelLogLine] = []

    private static let mono = Font.system(.caption, design: .monospaced)
    private static let green = Color(red: 0.25, green: 1.0, blue: 0.45)
    private static let blue = Color(red: 0.40, green: 0.62, blue: 1.0)
    private static let cyan = Color.cyan
    private static let purple = Color(red: 0.74, green: 0.52, blue: 1.0)

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                top
                VStack(alignment: .leading, spacing: 6) {
                    statusLine
                    proxyLine
                    cellularLine
                    serverLine
                    if tunnel.isConnected, let info = exitIP.info { exitLine(info) }
                    routingLine
                    powerLine
                    Text("-- sing-box log --")
                        .font(Self.mono)
                        .foregroundColor(.gray)
                        .padding(.top, 6)
                    logView
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Brand.gradient, lineWidth: 1)
                        .opacity(0.7)
                )
                .environment(\.colorScheme, .dark)
                HomeErrorBanner()
                bottom
            }
            .padding()
        }
        // Refreshes only while this layout is on screen; slows down when the phone runs hot.
        .task {
            while !Task.isCancelled {
                logLines = Array(EngineLogBuffer.shared.lines(after: 0).lines.suffix(14))
                try? await Task.sleep(for: .milliseconds(1500) * ThermalGuard.pollScale)
            }
        }
    }

    // MARK: Lines

    private var statusLine: some View {
        (Text("[STATUS]: ").foregroundColor(Self.cyan)
            + Text(tunnel.isConnected ? "CONNECTED" : tunnel.statusText.uppercased())
                .foregroundColor(tunnel.isConnected ? Self.green : Color.red))
            .font(Self.mono)
    }

    private var proxyLine: some View {
        (Text("[LOCAL_PROXY]: ").foregroundColor(Self.purple)
            + Text(tunnel.proxyEndpoint).foregroundColor(Self.blue)
            + Text(tunnel.isConnected ? " [OK]" : (tunnel.passthroughActive ? " [DIRECT]" : " [IDLE]"))
                .foregroundColor(tunnel.isConnected ? Self.green : Color.gray))
            .font(Self.mono)
    }

    private var cellularLine: some View {
        let state = tunnel.verifier.state
        let (text, color): (String, Color) = {
            switch state {
            case .verified: return ("VERIFIED & ACTIVE", Self.green)
            case .waiting: return ("AWAITING CELLULAR TRAFFIC", Color.orange)
            case .notCellular: return ("ON WI-FI", Color.gray)
            case .idle: return ("PROXY OFF", Color.gray)
            }
        }()
        return (Text("[CELLULAR_PROFILE]: ").foregroundColor(Self.cyan)
            + Text(text).foregroundColor(color))
            .font(Self.mono)
    }

    private var serverLine: some View {
        let node = nodes.activeNode
        var line = Text("[SELECTED_SERVER]: ").foregroundColor(Self.purple)
        if let node {
            line = line + Text(node.name + " ").foregroundColor(.white)
                + Text(node.displayServer.masked).foregroundColor(Self.blue)
            if let ms = node.latencyMs, ms > 0 {
                line = line + Text(" \(ms)ms").foregroundColor(Self.green)
            }
        } else {
            line = line + Text("NONE").foregroundColor(.gray)
        }
        return line.font(Self.mono)
    }

    private func exitLine(_ info: ExitIPStore.Info) -> some View {
        (Text("[EXIT_IP]: ").foregroundColor(Self.cyan)
            + Text("\(info.flag) ").foregroundColor(.white)
            + Text(info.maskedIP).foregroundColor(Self.blue))
            .font(Self.mono)
    }

    private var routingLine: some View {
        HStack(spacing: 8) {
            Text("[ROUTING]:").foregroundColor(Self.purple)
            ForEach(RoutingMode.allCases) { mode in
                let selected = settings.value.routingMode == mode
                Button { settings.value.routingMode = mode } label: {
                    Text(selected ? "[\(mode.title)]" : mode.title)
                        .foregroundColor(selected ? Brand.gold : Color.gray)
                        .fontWeight(selected ? .bold : .regular)
                }
                .buttonStyle(.plain)
            }
        }
        .font(Self.mono)
    }

    private var powerLine: some View {
        HStack(spacing: 12) {
            Text("[POWER]:").foregroundColor(Self.cyan)
            Button {
                if !tunnel.isConnected && !tunnel.isBusy { tunnel.toggle() }
            } label: {
                Text("[ ON ]")
                    .foregroundColor(tunnel.isConnected ? Self.green : Color.gray)
                    .fontWeight(tunnel.isConnected ? .bold : .regular)
            }
            .buttonStyle(.plain)
            Button {
                if tunnel.isConnected && !tunnel.isBusy { tunnel.toggle() }
            } label: {
                Text("[ OFF ]")
                    .foregroundColor(tunnel.isConnected ? Color.gray : Color.red)
                    .fontWeight(tunnel.isConnected ? .regular : .bold)
            }
            .buttonStyle(.plain)
        }
        .font(Self.mono)
    }

    private var logView: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if logLines.isEmpty {
                        Text("(no log lines yet; set Settings > Proxy & Engine > Log level to info to see DNS and connection lines)")
                            .font(Self.mono)
                            .foregroundColor(.gray)
                    }
                    ForEach(logLines) { line in
                        Text(Self.colorize(line.message))
                            .font(Self.mono)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
            }
            .frame(height: 220)
            .onChange(of: logLines.last?.id) { id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.2)) { reader.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    // MARK: Syntax highlighting

    private static let ipPattern = try? NSRegularExpression(pattern: #"\b\d{1,3}(?:\.\d{1,3}){3}(?::\d{1,5})?\b"#)
    private static let keyPattern = try? NSRegularExpression(pattern: #"\b(?:dns|inbound|outbound|router|connection|proxy|direct)\b"#, options: .caseInsensitive)
    private static let okPattern = try? NSRegularExpression(pattern: #"\b(?:connected|started|ok|verified|active)\b"#, options: .caseInsensitive)

    /// Colours one sing-box log line: IPs blue, `dns` / `inbound` / `outbound` style keys cyan,
    /// success words green; error lines red, warnings amber.
    static func colorize(_ message: String) -> AttributedString {
        var text = AttributedString(message)
        let lowered = message.lowercased()
        let base: Color
        if lowered.contains("error") || lowered.contains("fatal") {
            base = .red
        } else if lowered.contains("warn") {
            base = Brand.gold
        } else {
            base = Color(white: 0.78)
        }
        text.foregroundColor = base
        let full = NSRange(message.startIndex..., in: message)
        func paint(_ regex: NSRegularExpression?, _ color: Color) {
            guard let regex else { return }
            for match in regex.matches(in: message, range: full) {
                if let range = Range(match.range, in: text) {
                    text[range].foregroundColor = color
                }
            }
        }
        paint(keyPattern, cyan)
        paint(okPattern, green)
        paint(ipPattern, blue)
        return text
    }
}
