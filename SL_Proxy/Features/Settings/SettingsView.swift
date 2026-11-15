import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var nodes: NodeStore
    @EnvironmentObject private var tunnel: TunnelController
    @EnvironmentObject private var account: SLAccountStore
    @State private var confirmDeleteAll = false
    @State private var showAccount = false

    var body: some View {
        NavigationStack {
            ZStack {
                Brand.background
                Form {
                    Section {
                        Button {
                            showAccount = true
                        } label: {
                            HStack {
                                Label(account.isLoggedIn ? "SailorsLoot Account" : "Connect SailorsLoot Account",
                                      systemImage: "person.crop.circle")
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
                        NavigationLink {
                            LogsView(embedded: true)
                        } label: {
                            Label("Logs", systemImage: "doc.text.magnifyingglass")
                        }
                    }

                    Section {
                        DNSField(title: "Remote DNS (through proxy)", text: $settings.value.remoteDNS, presets: DNSPreset.remote)
                        DNSField(title: "Local DNS (direct)", text: $settings.value.localDNS, presets: DNSPreset.local)
                    } header: {
                        Text("DNS")
                    } footer: {
                        Text("Remote DNS resolves proxied traffic; local DNS resolves the proxy server and bypassed traffic.")
                    }

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
                    }

                    Section {
                        Toggle("IPv6", isOn: $settings.value.ipv6Enabled)
                        Toggle("Traffic sniffing", isOn: $settings.value.sniffing)
                    } header: {
                        Text("Engine")
                    } footer: {
                        Text("MTU, network stack and strict route only apply to the system VPN build; the user-space engine serves a plain HTTP + SOCKS5 listener.")
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
                        Text("Keep running in background plays a muted silent track and holds a background task while the proxy is on, so iOS does not suspend the \(tunnel.proxyEndpoint) listener when you switch apps or lock the screen. It switches off together with the proxy. Alert if SL_Proxy stops keeps a notification scheduled that is pushed back every few seconds; if iOS closes the app it fires, because the cellular profile cannot reach the proxy until you reopen SL_Proxy.")
                    }

                    Section("Advanced") {
                        NavigationLink("Appearance Settings") {
                            AppearanceSettingsView()
                        }
                        NavigationLink("Subscription Settings") {
                            SubscriptionSettingsView()
                        }
                        NavigationLink("Advanced & Pro Settings") {
                            AdvancedSettingsView()
                        }
                        NavigationLink("View generated sing-box config") {
                            ConfigPreviewView()
                        }
                        .disabled(nodes.activeNode == nil)
                        Button("Reset settings to defaults") { settings.reset() }
                        Button("Delete all servers and subscriptions", role: .destructive) {
                            confirmDeleteAll = true
                        }
                    }

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
                    } header: {
                        Text("Diagnostics")
                    } footer: {
                        Text("sing-box runs inside the app; no Network Extension, VPN profile or App Group is involved. Point Wi-Fi > Configure Proxy > Manual (or an app's SOCKS5 option) at the proxy address and keep SL_Proxy open while you use it.")
                    }

                    Section("About") {
                        LabeledContent("Version", value: "\(Bundle.main.shortVersion) (\(Bundle.main.buildNumber))")
                        LabeledContent("Core", value: "sing-box 1.11 (user-space)")
                        if let site = URL(string: "https://sailorsloot.xyz") {
                            Link("sailorsloot.xyz", destination: site)
                        }
                    }

                    Section("Credits") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("A Sailorsloot Project © 2026")
                                .font(.headline)
                                .foregroundStyle(Brand.gradient)
                            creditLine("@poshmipo", role: "Senior Developer")
                            creditLine("@Toolsbrain/Toolsbrain13723", role: "Developer")
                            creditLine("@9god", role: "Creator / Software manager")
                            creditLine("@cptkat", role: "UI designer / Developer")
                            creditLine("@ShadowH4ck3r", role: "uicache / logs input")
                            creditLine("@XYZ Aro El_ArbustoGato III", role: "Proxy Address Engine Config Creator")
                        }
                        .padding(.vertical, 4)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showAccount) { AccountView() }
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

    private var localProxyFooter: String {
        let range = AppSettings.localProxyPortRange
        var text = "The HTTP + SOCKS5 listener binds to \(AppSettings.localProxyHost) on this port. "
            + "The default is \(AppSettings.defaultLocalProxyPort); 1080 is avoided because other proxy tools usually hold it. "
            + "Ports \(range.lowerBound) to \(range.upperBound) are accepted; anything else falls back to \(AppSettings.defaultLocalProxyPort)."
        if settings.value.localProxyPortFallback {
            text += " When the port is busy, the presets are tried in order, then the next free port upward; the address in use is shown above and on Home."
        }
        if tunnel.isOnFallbackPort, let port = tunnel.activePort {
            text += " Currently on \(port) because \(settings.value.effectiveLocalProxyPort) was in use."
        }
        return text
    }

    private func creditLine(_ handle: String, role: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(handle)
                .font(.subheadline.weight(.semibold))
            Text("(\(role))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

private struct DNSField: View {
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
private struct PortField: View {
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
