import SwiftUI

/// Settings, laid out like V2Box: the account row, then one stacked list of pages. Each page holds
/// one topic (Appearance, Proxy & Engine, DNS, Subscriptions, Advanced, Diagnostics, Logs, About).
struct SettingsView: View {
    @EnvironmentObject private var account: SLAccountStore
    @EnvironmentObject private var ota: OTAManager
    @EnvironmentObject private var tunnel: TunnelController
    @EnvironmentObject private var language: LanguageStore
    @State private var showAccount = false

    var body: some View {
        NavigationStack {
            ZStack {
                Brand.background
                Form {
                    if !ota.components(for: "settings.top").isEmpty {
                        Section {
                            DynamicOTAView(placement: "settings.top")
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                    }

                    Section {
                        Button {
                            showAccount = true
                        } label: {
                            HStack {
                                SettingsRow(
                                    title: account.isLoggedIn ? "SailorsLoot Account" : "Connect SailorsLoot Account",
                                    systemImage: "person.crop.circle"
                                )
                                Spacer()
                                Text(account.isLoggedIn ? account.balanceText : "")
                                    .font(.footnote.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .foregroundStyle(.primary)
                    }

                    // Live speed and chart: moved here from Home (Home shows it again only when the
                    // OTA flag hide_home_chart is false in ui.json).
                    Section {
                        TrafficCard(traffic: tunnel.traffic)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                            .listRowBackground(Color.clear)
                    } header: {
                        Text("Live Traffic")
                    }

                    Section {
                        Picker(selection: $language.code) {
                            ForEach(AppLanguage.all) { option in
                                Text(option.nativeName).tag(option.code)
                            }
                        } label: {
                            SettingsRow(title: "Language", systemImage: "character.bubble")
                        }
                        .pickerStyle(.menu)
                    }

                    Section {
                        NavigationLink { AppearanceSettingsView() } label: {
                            SettingsRow(title: "Appearance", systemImage: "circle.lefthalf.filled")
                        }
                        NavigationLink { ProxyEngineSettingsView() } label: {
                            SettingsRow(title: "Proxy & Engine", systemImage: "point.3.connected.trianglepath.dotted")
                        }
                        NavigationLink { DNSSettingsView() } label: {
                            SettingsRow(title: "DNS Settings", systemImage: "network")
                        }
                        NavigationLink { SubscriptionSettingsView() } label: {
                            SettingsRow(title: "Subscription Settings", systemImage: "link")
                        }
                        NavigationLink { AdvancedSettingsView() } label: {
                            SettingsRow(title: "Advanced Settings", systemImage: "slider.horizontal.3")
                        }
                        NavigationLink { DiagnosticsView() } label: {
                            SettingsRow(title: "Diagnostics", systemImage: "waveform.path.ecg")
                        }
                        NavigationLink { LogsView(embedded: true) } label: {
                            SettingsRow(title: "Logs", systemImage: "doc.text.magnifyingglass")
                        }
                        NavigationLink { AboutView() } label: {
                            SettingsRow(title: "About", systemImage: "info.circle")
                        }
                    } header: {
                        Text("Settings")
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showAccount) { AccountView() }
        }
    }
}

/// One row of the stacked Settings list: a small brand-coloured icon tile and the title.
struct SettingsRow: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 28, height: 28)
                .background(Brand.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(LocalizedStringKey(title))
        }
    }
}

// MARK: - Proxy & Engine

private struct ProxyEngineSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var tunnel: TunnelController

    var body: some View {
        ZStack {
            Brand.background
            Form {
                Section {
                    PortField(
                        title: "Listen port",
                        port: $settings.value.localProxyPort,
                        presets: AppSettings.localProxyPortOptions
                    )
                    Toggle("Try other ports if busy", isOn: $settings.value.localProxyPortFallback)
                    LabeledContent("Listening on", value: tunnel.isConnected ? tunnel.proxyEndpoint : "Not running")
                } header: {
                    Text("Local proxy")
                } footer: {
                    Text(localProxyFooter)
                        .font(.caption2)
                }

                Section {
                    Toggle("IPv6", isOn: $settings.value.ipv6Enabled)
                    Toggle("Traffic sniffing", isOn: $settings.value.sniffing)
                } header: {
                    Text("Engine")
                } footer: {
                    Text("MTU, network stack and strict route only apply to the system VPN build; the user-space engine serves a plain HTTP + SOCKS5 listener.")
                        .font(.caption2)
                }

                Section {
                    Toggle("Connect on launch", isOn: $settings.value.autoConnectOnLaunch)
                    Toggle("Keep running in background", isOn: $settings.value.keepAliveInBackground)
                    Toggle("Alert if SL_Proxy stops", isOn: $settings.value.engineWatchdog)
                    LabeledContent("Background keep-alive", value: tunnel.backgroundKeepAliveActive ? "Active" : "Off")
                    Picker("Log level", selection: $settings.value.logLevel) {
                        ForEach(AppSettings.logLevels, id: \.self) { level in
                            Text(level).tag(level)
                        }
                    }
                } header: {
                    Text("Behaviour")
                } footer: {
                    Text("Keep running in background plays a muted silent track so iOS does not suspend the listener when you switch apps or lock the screen. Alert if SL_Proxy stops sends a notification if iOS closes the app, because the cellular profile cannot reach the proxy until you reopen SL_Proxy.")
                        .font(.caption2)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Proxy & Engine")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var localProxyFooter: String {
        let range = AppSettings.localProxyPortRange
        var text = "The HTTP + SOCKS5 listener binds to \(AppSettings.localProxyHost) on this port. "
            + "The default is \(AppSettings.defaultLocalProxyPort); 1080 is avoided because other proxy tools usually hold it. "
            + "Ports \(range.lowerBound) to \(range.upperBound) are accepted; anything else falls back to \(AppSettings.defaultLocalProxyPort)."
        if settings.value.localProxyPortFallback {
            text += " When the port is busy, the presets are tried in order, then the next free port upward."
        }
        if tunnel.isOnFallbackPort, let port = tunnel.activePort {
            text += " Currently on \(port) because \(settings.value.effectiveLocalProxyPort) was in use."
        }
        return text
    }
}

// MARK: - DNS

private struct DNSSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @StateObject private var systemDNS = SystemDNSManager()
    @AppStorage("systemEncryptedDNS") private var systemDNSOn = false
    @AppStorage("tunnelDNSThroughProxy") private var tunnelDNSOn = false

    var body: some View {
        ZStack {
            Brand.background
            Form {
                Section {
                    DNSField(title: tunnelDNSOn ? "Remote DNS (through proxy)" : "Remote DNS (encrypted, direct)", text: $settings.value.remoteDNS, presets: DNSPreset.remote)
                    DNSField(title: "Local DNS (direct)", text: $settings.value.localDNS, presets: DNSPreset.local)
                } footer: {
                    Text("Remote DNS resolves proxied traffic; local DNS resolves the proxy server and bypassed traffic.")
                        .font(.caption2)
                }

                Section {
                    Toggle("Tunnel DNS through proxy (experimental)", isOn: $tunnelDNSOn)
                } footer: {
                    Text("Sends Remote DNS lookups through your proxy, so the resolver sees the proxy's country instead of the nearest one to you. Slower first loads, and the proxy must allow connections to your DNS server. If connections stop working, turn it off. Reconnect after changing it.")
                        .font(.caption2)
                }

                Section {
                    Toggle("System Encrypted DNS (No VPN Icon)", isOn: $systemDNSOn)
                        .disabled(systemDNS.isBusy)
                    if systemDNSOn, systemDNS.isEnabled == false {
                        Text("Almost done: open iOS Settings > General > VPN & Device Management > DNS and select SL_Proxy Encrypted DNS.")
                            .font(.footnote)
                            .foregroundStyle(Brand.gold)
                    }
                    if let message = systemDNS.message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("System DNS")
                } footer: {
                    Text("Mirrors your Remote DNS into iOS as a DoH / DoT profile, so the whole system resolves over encrypted DNS without a VPN icon. Needs a DoH (https://) or DoT (tls://) Remote DNS. Reconnect after changing it so the proxy picks up the new setting.")
                        .font(.caption2)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("DNS Settings")
        .navigationBarTitleDisplayMode(.inline)
        .task { await systemDNS.refresh() }
        .onChange(of: systemDNSOn) { enabled in
            Task {
                if enabled { await systemDNS.apply(remoteDNS: settings.value.remoteDNS) } else { await systemDNS.remove() }
            }
        }
        // Keep the system profile in step with the Remote DNS the user picks.
        .onChange(of: settings.value.remoteDNS) { value in
            guard systemDNSOn else { return }
            Task { await systemDNS.apply(remoteDNS: value) }
        }
    }
}

// MARK: - Diagnostics

private struct DiagnosticsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var nodes: NodeStore
    @EnvironmentObject private var tunnel: TunnelController
    @State private var confirmDeleteAll = false

    var body: some View {
        ZStack {
            Brand.background
            Form {
                Section {
                    LabeledContent("Mode", value: "User-space loopback")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Proxy address (HTTP + SOCKS5)")
                        Text(tunnel.proxyEndpoint)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    if tunnel.isOnFallbackPort {
                        LabeledContent("Port", value: "Fallback (\(settings.value.effectiveLocalProxyPort) was busy)")
                    }
                    LabeledContent("Engine", value: tunnel.statusText)
                    if let server = tunnel.activeServerName {
                        LabeledContent("Routing through", value: server)
                    }
                    NavigationLink("View generated sing-box config") {
                        ConfigPreviewView()
                    }
                    .disabled(nodes.activeNode == nil)
                } footer: {
                    Text("sing-box runs inside the app; no Network Extension, VPN profile or App Group is involved. Keep SL_Proxy open while you use the proxy address.")
                        .font(.caption2)
                }

                Section {
                    Button("Reset settings to defaults") { settings.reset() }
                    Button("Delete all servers and subscriptions", role: .destructive) {
                        confirmDeleteAll = true
                    }
                } header: {
                    Text("Data")
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Delete all servers and subscriptions?",
            isPresented: $confirmDeleteAll,
            titleVisibility: .visible
        ) {
            Button("Delete all", role: .destructive) {
                nodes.deleteAll()
                Task { await tunnel.stop() }
            }
        }
    }
}

struct DNSField: View {
    let title: String
    @Binding var text: String
    let presets: [DNSPreset]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Menu {
                    ForEach(presets) { preset in
                        Button(preset.name) { text = preset.address }
                    }
                } label: {
                    Label("Presets", systemImage: "list.bullet")
                        .font(.caption)
                }
            }
            TextField("Address", text: $text)
                .font(.system(.footnote, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
        }
        .padding(.vertical, 2)
    }
}

/// Numeric port editor with a preset menu, mirroring `DNSField`.
struct PortField: View {
    let title: String
    @Binding var port: Int
    let presets: [Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Menu {
                    ForEach(presets, id: \.self) { preset in
                        Button(String(preset)) { port = preset }
                    }
                } label: {
                    Label("Presets", systemImage: "list.bullet")
                        .font(.caption)
                }
            }
            TextField("Port", value: $port, format: .number.grouping(.never))
                .font(.system(.footnote, design: .monospaced))
                .keyboardType(.numberPad)
            if !AppSettings.isValidLocalProxyPort(port) {
                Text("Use a port between \(AppSettings.localProxyPortRange.lowerBound) and \(AppSettings.localProxyPortRange.upperBound) (not 9090); \(AppSettings.defaultLocalProxyPort) is used until then.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }
}

struct ConfigPreviewView: View {
    @EnvironmentObject private var nodes: NodeStore
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        let config = nodes.previewConfig(settings: settings.value) ?? "Select a server first."
        ZStack {
            Brand.background
            ScrollView {
                Text(config)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
        .navigationTitle("sing-box config")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button {
                UIPasteboard.general.string = config
                nodes.toast = "Config copied"
            } label: {
                Image(systemName: "doc.on.doc")
            }
        }
    }
}
