import SwiftUI

/// Proxy Share Settings: exposes the HTTP + SOCKS5 listener on a physical interface.
///
/// Bound to `AppSettings` through `SettingsStore`; `TunnelController` picks changes up via
/// `applyChanges()`, binds a second mixed inbound to the IPv4 address of the selected interface and
/// reports the port actually bound (`activeSharePort`) when the chosen one was busy and the engine
/// scanned upward. The status row probes the chosen port by briefly binding a TCP socket
/// (`PortProbe`) whenever the port or interface changes.
///
/// The Sharing section also opens the QR code for the shared endpoint (`ProxyShareQRSheet`) and the
/// live list of devices using it (`ConnectedClientsView`). Authentication puts a username and
/// password on the shared listener only, and Auto-config runs the `PACServer` next to it.
struct ProxyShareSettingsView: View {
    private static let portRange = AppSettings.localProxyPortRange

    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var tunnel: TunnelController
    @EnvironmentObject private var nodes: NodeStore

    /// Text mirror of `settings.value.sharePort`; half-typed values are not written to Settings.
    @State private var portText = ""
    /// Text mirror of `settings.value.pacPort`.
    @State private var pacPortText = ""
    /// Text mirrors of the credentials; written to Settings when a field is submitted or the screen
    /// is left, so the core is not restarted on every keystroke.
    @State private var usernameText = ""
    @State private var passwordText = ""
    @State private var portStatus: PortStatus = .unknown
    @State private var interfaceAddress: String?
    @State private var showQRCode = false

    private enum PortStatus: Equatable {
        case unknown, checking, available, inUse, listening, invalid
    }

    var body: some View {
        ZStack {
            Brand.background
            Form {
                Section {
                    Picker("Select Interface", selection: $settings.value.shareInterface) {
                        ForEach(ShareInterface.allCases) { interface in
                            Text(interface.title).tag(interface)
                        }
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("Interface")
                } footer: {
                    Text("Network interface the shared proxy listens on.")
                    .font(.caption2)
                }

                Section {
                    Text("LAN SHARING (IP: \(interfaceAddress ?? "unavailable"))")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.gradient)
                    Toggle("Share SOCKS5 & HTTP", isOn: $settings.value.shareEnabled)
                    if let endpoint = tunnel.shareEndpoint {
                        LabeledContent("Listening on", value: endpoint)
                    }
                    Button {
                        showQRCode = true
                    } label: {
                        Label("Show QR Code", systemImage: "qrcode")
                    }
                    .disabled(tunnel.shareAdvertisedAddress == nil)
                    NavigationLink {
                        ConnectedClientsView()
                    } label: {
                        HStack {
                            Label("Connected Clients", systemImage: "person.2.wave.2")
                            Spacer()
                            ConnectedClientsBadge(monitor: tunnel.clients)
                        }
                    }
                } header: {
                    Text("Sharing")
                } footer: {
                    Text(sharingFooter)
                    .font(.caption2)
                }

                Section {
                    HStack(spacing: 12) {
                        Text("SOCKS Port")
                        Spacer()
                        TextField(String(AppSettings.defaultSharePort), text: $portText)
                            .font(.system(.body, design: .monospaced))
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                            .frame(maxWidth: 120)
                        Button {
                            setPort(Self.randomPort())
                        } label: {
                            Image(systemName: "dice")
                                .font(.body.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .tint(Brand.orange)
                        .accessibilityLabel("Random port")
                    }
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                        Text(statusText)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Port")
                } footer: {
                    Text(portFooter)
                    .font(.caption2)
                }

                Section {
                    Toggle("Require username & password", isOn: $settings.value.shareAuthEnabled)
                    if settings.value.shareAuthEnabled {
                        TextField("Username", text: $usernameText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.username)
                            .onSubmit { commitCredentials() }
                        HStack(spacing: 12) {
                            SecureField("Password", text: $passwordText)
                                .textContentType(.password)
                                .onSubmit { commitCredentials() }
                            Button {
                                passwordText = AppSettings.randomSharePassword()
                                commitCredentials()
                            } label: {
                                Image(systemName: "wand.and.stars")
                                    .font(.body.weight(.semibold))
                            }
                            .buttonStyle(.bordered)
                            .tint(Brand.orange)
                            .accessibilityLabel("Generate password")
                        }
                        if settings.value.shareCredentials == nil {
                            Label("Not enforced until both fields are filled in.", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                } header: {
                    Text("Authentication")
                } footer: {
                    Text(authFooter)
                    .font(.caption2)
                }

                Section {
                    Toggle("Serve proxy.pac", isOn: $settings.value.pacEnabled)
                    if settings.value.pacEnabled {
                        HStack(spacing: 12) {
                            Text("PAC Port")
                            Spacer()
                            TextField(String(AppSettings.defaultPACPort), text: $pacPortText)
                                .font(.system(.body, design: .monospaced))
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.numberPad)
                                .frame(maxWidth: 120)
                        }
                        if let url = tunnel.pacURL {
                            HStack(spacing: 12) {
                                Text(url)
                                    .font(.system(.footnote, design: .monospaced))
                                    .foregroundStyle(tunnel.activePACPort != nil ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(.secondary))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                                Spacer()
                                Button {
                                    UIPasteboard.general.string = url
                                    nodes.toast = "PAC URL copied"
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                        .font(.footnote.weight(.semibold))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Auto-config (PAC)")
                } footer: {
                    Text(pacFooter)
                    .font(.caption2)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Proxy Share")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showQRCode) {
            ProxyShareQRSheet()
        }
        .onAppear {
            portText = String(settings.value.sharePort)
            pacPortText = String(settings.value.pacPort)
            usernameText = settings.value.shareUsername
            passwordText = settings.value.sharePassword
            interfaceAddress = NetworkInterfaces.ipv4Address(of: settings.value.shareInterface)
        }
        .onDisappear {
            commitCredentials()
        }
        .onChange(of: settings.value.shareInterface) { interface in
            interfaceAddress = NetworkInterfaces.ipv4Address(of: interface)
        }
        .onChange(of: settings.value.shareAuthEnabled) { _ in
            commitCredentials()
        }
        .onChange(of: portText) { text in
            guard let port = Int(text), AppSettings.isValidLocalProxyPort(port) else { return }
            if settings.value.sharePort != port { settings.value.sharePort = port }
        }
        .onChange(of: pacPortText) { text in
            guard let port = Int(text), AppSettings.isValidLocalProxyPort(port) else { return }
            if settings.value.pacPort != port { settings.value.pacPort = port }
        }
        .task(id: probeKey) {
            await probePort()
        }
    }

    // MARK: - Port probe

    /// Re-runs the probe when the port, the interface address or the running listener changes.
    private var probeKey: String {
        "\(portText)|\(interfaceAddress ?? "-")|\(tunnel.activeShareAddress ?? "-"):\(tunnel.activeSharePort ?? 0)"
    }

    /// Binds a TCP socket to the address the share listener would use (the interface IP, or
    /// 127.0.0.1 while the interface has none) and releases it, then updates the indicator.
    private func probePort() async {
        guard let port = Int(portText), AppSettings.isValidLocalProxyPort(port) else {
            portStatus = .invalid
            return
        }
        let host = interfaceAddress ?? AppSettings.localProxyHost
        if tunnel.activeSharePort == port, tunnel.activeShareAddress == host {
            portStatus = .listening
            return
        }
        portStatus = .checking
        // Debounce typing so every keystroke does not open a socket.
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let free = await PortProbe.check(port, host: host)
        guard !Task.isCancelled else { return }
        portStatus = free ? .available : .inUse
    }

    private var statusColor: Color {
        switch portStatus {
        case .available, .listening: return .green
        case .inUse: return .red
        case .invalid: return .orange
        case .checking, .unknown: return .gray
        }
    }

    private var statusText: String {
        switch portStatus {
        case .available: return "Available"
        case .inUse: return "In Use"
        case .listening: return "In Use by SL_Proxy (listening)"
        case .invalid: return "Enter a port between \(Self.portRange.lowerBound) and \(Self.portRange.upperBound) (not 9090)"
        case .checking: return "Checking…"
        case .unknown: return "Not checked"
        }
    }

    // MARK: - Text

    private var sharingFooter: String {
        var text = "Lets other devices on the same network use this proxy. The listener binds to the "
            + "\(settings.value.shareInterface.title) address shown above"
        if interfaceAddress == nil {
            text += "; that interface has no IPv4 address right now, so only the loopback listener runs until it comes up"
        }
        text += "."
        if tunnel.isOnFallbackSharePort, let port = tunnel.activeSharePort {
            text += " Currently on port \(port) because \(settings.value.effectiveSharePort) was in use."
        }
        if let endpoint = tunnel.shareAdvertisedEndpoint {
            text += " Clients dial \(endpoint); the QR code carries that address."
        }
        return text
    }

    private var portFooter: String {
        "Default \(AppSettings.defaultSharePort). The dice picks a random port between "
            + "\(Self.portRange.lowerBound) and \(Self.portRange.upperBound). When the port is busy at start, "
            + "the engine takes the next free port upward and shows it here."
    }

    private var authFooter: String {
        var text = "Clients must send this username and password (HTTP Basic or SOCKS5 username/password) "
            + "to use the shared listener. The loopback listener at \(tunnel.proxyEndpoint) stays open for apps on this device."
        if settings.value.shareAuthEnabled {
            text += " Changes apply when you leave a field."
        }
        return text
    }

    private var pacFooter: String {
        var text = "Serves a proxy auto-config script on the \(settings.value.shareInterface.title) address, "
            + "port \(settings.value.effectivePACPort). On the client, set Wi-Fi > Configure Proxy > Automatic to the URL above."
        if let active = tunnel.activePACPort, active != settings.value.effectivePACPort {
            text += " Currently on port \(active) because \(settings.value.effectivePACPort) was in use."
        }
        if settings.value.shareCredentials != nil {
            text += " A PAC file cannot carry credentials, so the client asks for the username and password once."
        }
        return text
    }

    // MARK: - Helpers

    private func setPort(_ port: Int) {
        portText = String(port)
        settings.value.sharePort = port
    }

    /// Writes the credential fields to Settings when they differ from the stored values.
    private func commitCredentials() {
        let user = usernameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.value.shareUsername != user { settings.value.shareUsername = user }
        if settings.value.sharePassword != passwordText { settings.value.sharePassword = passwordText }
    }

    private static func randomPort() -> Int {
        var port: Int
        repeat {
            port = Int.random(in: portRange)
        } while !AppSettings.isValidLocalProxyPort(port)
        return port
    }
}

/// Live count of devices using the shared listener, shown next to the Connected Clients link.
private struct ConnectedClientsBadge: View {
    @ObservedObject var monitor: ConnectedClientsMonitor

    var body: some View {
        let count = monitor.activeCount
        Text("\(count)")
            .font(.caption.monospacedDigit().weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background((count > 0 ? Color.green : Color.gray).opacity(0.18), in: Capsule())
            .foregroundStyle(count > 0 ? Color.green : Color.secondary)
    }
}
