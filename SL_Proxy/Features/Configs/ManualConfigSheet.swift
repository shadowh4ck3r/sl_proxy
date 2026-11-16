import SwiftUI

/// Hand-entered server editor in the spirit of V2Box / Shadowrocket: pick a protocol, fill in the
/// fields, save. The same sheet edits an existing server. Every field maps onto the flat
/// `ProxyNode` model, so nothing depends on scanning or pasting a share link.
struct ManualConfigSheet: View {
    @EnvironmentObject private var nodes: NodeStore
    @EnvironmentObject private var tunnel: TunnelController
    @Environment(\.dismiss) private var dismiss

    private let existing: ProxyNode?
    @State private var draft: ServerDraft
    @State private var revealSecrets = false

    init(node: ProxyNode? = nil) {
        existing = node
        _draft = State(initialValue: node.map(ServerDraft.init) ?? ServerDraft())
    }

    private var validationError: String? { draft.validationError }
    private var isValid: Bool { validationError == nil }

    var body: some View {
        NavigationStack {
            ZStack {
                Brand.background
                Form {
                    serverSection
                    protocolSections
                    if let validationError {
                        Section {
                            Label(validationError, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                    Section {
                        Button(existing == nil ? "Save server" : "Save changes") { save() }
                            .buttonStyle(BrandButtonStyle())
                            .disabled(!isValid)
                            .opacity(isValid ? 1 : 0.5)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(existing == nil ? "Add server" : "Edit server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!isValid)
                }
            }
        }
    }

    // MARK: - Sections

    private var serverSection: some View {
        Section {
            Picker("Type", selection: $draft.kind) {
                ForEach(ProxyKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            LabeledContent("Name") {
                TextField("Optional", text: $draft.name)
                    .multilineTextAlignment(.trailing)
            }
            valueRow("Address", placeholder: "host or IP", text: $draft.server, keyboard: .URL)
            valueRow("Port", placeholder: "443", text: $draft.port, keyboard: .numberPad)
        } header: {
            Text("Server")
        } footer: {
            Text(kindHint)
                    .font(.caption2)
        }
    }

    @ViewBuilder
    private var protocolSections: some View {
        switch draft.kind {
        case .socks:
            Section {
                valueRow("Username", placeholder: "Optional", text: $draft.username)
                secretRow("Password", placeholder: "Optional", text: $draft.password)
            } header: {
                Text("Authentication")
            } footer: {
                Text("Leave both fields empty when the SOCKS5 server does not require a login.")
                    .font(.caption2)
            }

        case .http:
            Section("Authentication") {
                valueRow("Username", placeholder: "Optional", text: $draft.username)
                secretRow("Password", placeholder: "Optional", text: $draft.password)
            }
            tlsSection(alwaysOn: false, reality: false, fingerprint: false)

        case .shadowsocks:
            Section("Shadowsocks") {
                Picker("Method", selection: $draft.method) {
                    ForEach(ServerDraft.shadowsocksMethods, id: \.self) { Text($0).tag($0) }
                }
                secretRow("Password", placeholder: "Required", text: $draft.password)
            }
            Section("Plugin") {
                valueRow("Plugin", placeholder: "obfs-local, v2ray-plugin", text: $draft.plugin)
                valueRow("Options", placeholder: "obfs=http;obfs-host=…", text: $draft.pluginOpts)
            }

        case .vmess:
            Section("VMess") {
                uuidRow
                valueRow("Alter ID", placeholder: "0", text: $draft.alterId, keyboard: .numberPad)
                Picker("Security", selection: $draft.security) {
                    ForEach(ServerDraft.vmessSecurities, id: \.self) { Text($0).tag($0) }
                }
            }
            transportSection
            tlsSection(alwaysOn: false, reality: false, fingerprint: true)

        case .vless:
            Section("VLESS") {
                uuidRow
                valueRow("Flow", placeholder: "xtls-rprx-vision (optional)", text: $draft.flow)
            }
            transportSection
            tlsSection(alwaysOn: false, reality: true, fingerprint: true)

        case .trojan:
            Section("Trojan") {
                secretRow("Password", placeholder: "Required", text: $draft.password)
            }
            transportSection
            tlsSection(alwaysOn: true, reality: false, fingerprint: true)

        case .hysteria:
            Section("Hysteria") {
                secretRow("Auth", placeholder: "Optional", text: $draft.password)
                valueRow("Obfs", placeholder: "Optional", text: $draft.obfs)
                bandwidthRows
            }
            tlsSection(alwaysOn: true, reality: false, fingerprint: false)

        case .hysteria2:
            Section("Hysteria2") {
                secretRow("Password", placeholder: "Required", text: $draft.password)
                Picker("Obfuscation", selection: $draft.obfsType) {
                    Text("None").tag("none")
                    Text("Salamander").tag("salamander")
                }
                if draft.obfsType != "none" {
                    secretRow("Obfs password", placeholder: "Required", text: $draft.obfsPassword)
                }
                bandwidthRows
            }
            tlsSection(alwaysOn: true, reality: false, fingerprint: true)

        case .tuic:
            Section("TUIC") {
                uuidRow
                secretRow("Password", placeholder: "Required", text: $draft.password)
                Picker("Congestion control", selection: $draft.congestionControl) {
                    ForEach(ServerDraft.congestionControls, id: \.self) { Text($0).tag($0) }
                }
                Picker("UDP relay mode", selection: $draft.udpRelayMode) {
                    ForEach(ServerDraft.udpRelayModes, id: \.self) { Text($0).tag($0) }
                }
            }
            tlsSection(alwaysOn: true, reality: false, fingerprint: false)

        case .wireguard:
            Section("WireGuard") {
                secretRow("Private key", placeholder: "Required", text: $draft.privateKey)
                valueRow("Peer public key", placeholder: "Required", text: $draft.peerPublicKey)
                secretRow("Pre-shared key", placeholder: "Optional", text: $draft.preSharedKey)
            }
            Section {
                valueRow("Local address", placeholder: "10.0.0.2/32, fd00::2/128", text: $draft.localAddress)
                valueRow("MTU", placeholder: "1408", text: $draft.mtu, keyboard: .numberPad)
                valueRow("Reserved", placeholder: "0,0,0", text: $draft.reserved)
            } header: {
                Text("Interface")
            } footer: {
                Text("Comma separated lists. Reserved bytes are only needed by some providers (for example WARP).")
                    .font(.caption2)
            }
        }
    }

    private var transportSection: some View {
        Section("Transport") {
            Picker("Network", selection: $draft.transport) {
                ForEach(TransportKind.allCases, id: \.self) { transport in
                    Text(ServerDraft.title(for: transport)).tag(transport)
                }
            }
            switch draft.transport {
            case .ws, .http, .httpupgrade:
                valueRow("Path", placeholder: "/", text: $draft.path, keyboard: .URL)
                valueRow("Host", placeholder: "Optional", text: $draft.host, keyboard: .URL)
            case .grpc:
                valueRow("Service name", placeholder: "Required", text: $draft.serviceName)
            case .tcp, .quic:
                EmptyView()
            }
        }
    }

    private func tlsSection(alwaysOn: Bool, reality: Bool, fingerprint: Bool) -> some View {
        Section {
            if alwaysOn {
                LabeledContent("TLS", value: "Always on")
            } else {
                Toggle("TLS", isOn: $draft.tls)
            }
            if alwaysOn || draft.tls || (reality && !draft.realityPublicKey.isEmpty) {
                valueRow("SNI", placeholder: "Optional", text: $draft.sni, keyboard: .URL)
                valueRow("ALPN", placeholder: "h2,http/1.1", text: $draft.alpn)
                if fingerprint {
                    valueRow("Fingerprint", placeholder: "chrome", text: $draft.fingerprint)
                }
                Toggle("Allow insecure", isOn: $draft.insecure)
            }
            if reality {
                valueRow("Reality public key", placeholder: "Optional", text: $draft.realityPublicKey)
                valueRow("Reality short ID", placeholder: "Optional", text: $draft.realityShortID)
            }
        } header: {
            Text("TLS")
        }
    }

    // MARK: - Rows

    private var uuidRow: some View {
        LabeledContent("UUID") {
            HStack(spacing: 8) {
                TextField("Required", text: $draft.uuid)
                    .multilineTextAlignment(.trailing)
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    draft.uuid = UUID().uuidString.lowercased()
                } label: {
                    Image(systemName: "dice")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder
    private var bandwidthRows: some View {
        valueRow("Upload Mbps", placeholder: "Optional", text: $draft.upMbps, keyboard: .numberPad)
        valueRow("Download Mbps", placeholder: "Optional", text: $draft.downMbps, keyboard: .numberPad)
    }

    private func valueRow(
        _ title: String,
        placeholder: String,
        text: Binding<String>,
        keyboard: UIKeyboardType = .default
    ) -> some View {
        LabeledContent(title) {
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
        }
    }

    private func secretRow(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Group {
                    if revealSecrets {
                        TextField(placeholder, text: text)
                    } else {
                        SecureField(placeholder, text: text)
                    }
                }
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(.body, design: .monospaced))
                Button {
                    revealSecrets.toggle()
                } label: {
                    Image(systemName: revealSecrets ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var kindHint: String {
        switch draft.kind {
        case .socks: return "Plain SOCKS5 proxy. Add a username and password if the server requires a login."
        case .http: return "HTTP proxy, optionally over TLS (HTTPS)."
        case .shadowsocks: return "Shadowsocks with an optional SIP003 plugin."
        case .vmess: return "VMess over TCP, WebSocket, gRPC, HTTP/2, HTTPUpgrade or QUIC."
        case .vless: return "VLESS, including XTLS Vision flow and Reality."
        case .trojan: return "Trojan always uses TLS."
        case .hysteria: return "Hysteria v1 over QUIC."
        case .hysteria2: return "Hysteria2 over QUIC with optional Salamander obfuscation."
        case .tuic: return "TUIC v5 over QUIC."
        case .wireguard: return "WireGuard peer handled by the sing-box core."
        }
    }

    // MARK: - Actions

    private func save() {
        guard isValid else { return }
        var node = draft.makeNode()
        if let existing {
            node.id = existing.id
            node.subscriptionID = existing.subscriptionID
            let wasActive = nodes.update(node)
            nodes.toast = "Server updated"
            if wasActive { tunnel.applyChanges() }
        } else {
            nodes.add(node)
            nodes.toast = "Server added"
        }
        dismiss()
    }
}

// MARK: - Draft

/// String-backed, editable mirror of `ProxyNode` used by the form.
struct ServerDraft {
    static let shadowsocksMethods = [
        "aes-128-gcm", "aes-256-gcm", "chacha20-ietf-poly1305", "xchacha20-ietf-poly1305",
        "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305", "none",
    ]
    static let vmessSecurities = ["auto", "aes-128-gcm", "chacha20-poly1305", "none", "zero"]
    static let congestionControls = ["bbr", "cubic", "new_reno"]
    static let udpRelayModes = ["native", "quic"]

    var kind: ProxyKind = .socks
    var name = ""
    var server = ""
    var port = ""

    var uuid = ""
    var password = ""
    var username = ""
    var method = "aes-256-gcm"
    var security = "auto"
    var alterId = "0"
    var flow = ""

    var tls = false
    var sni = ""
    var insecure = false
    var alpn = ""
    var fingerprint = ""
    var realityPublicKey = ""
    var realityShortID = ""

    var transport: TransportKind = .tcp
    var path = ""
    var host = ""
    var serviceName = ""

    var plugin = ""
    var pluginOpts = ""

    var obfs = ""
    var obfsType = "none"
    var obfsPassword = ""
    var upMbps = ""
    var downMbps = ""

    var congestionControl = "bbr"
    var udpRelayMode = "native"

    var privateKey = ""
    var peerPublicKey = ""
    var preSharedKey = ""
    var localAddress = ""
    var mtu = ""
    var reserved = ""

    init() {}

    init(_ n: ProxyNode) {
        kind = n.kind
        name = n.name
        server = n.server
        port = String(n.port)
        uuid = n.uuid ?? ""
        password = n.password ?? ""
        username = n.username ?? ""
        method = n.method ?? "aes-256-gcm"
        security = n.security ?? "auto"
        alterId = String(n.alterId ?? 0)
        flow = n.flow ?? ""
        tls = n.tls
        sni = n.sni ?? ""
        insecure = n.insecure
        alpn = n.alpn.joined(separator: ",")
        fingerprint = n.fingerprint ?? ""
        realityPublicKey = n.realityPublicKey ?? ""
        realityShortID = n.realityShortID ?? ""
        transport = n.transport
        path = n.path ?? ""
        host = n.host ?? ""
        serviceName = n.serviceName ?? ""
        plugin = n.plugin ?? ""
        pluginOpts = n.pluginOpts ?? ""
        if n.kind == .hysteria2 {
            obfsType = n.obfs?.nonEmpty ?? "none"
            obfsPassword = n.obfsPassword ?? ""
        } else {
            obfs = n.obfs ?? ""
        }
        upMbps = n.upMbps.map { String($0) } ?? ""
        downMbps = n.downMbps.map { String($0) } ?? ""
        congestionControl = n.congestionControl ?? "bbr"
        udpRelayMode = n.udpRelayMode ?? "native"
        privateKey = n.privateKey ?? ""
        peerPublicKey = n.peerPublicKey ?? ""
        preSharedKey = n.preSharedKey ?? ""
        localAddress = n.localAddress.joined(separator: ", ")
        mtu = n.mtu.map { String($0) } ?? ""
        reserved = n.reserved.map { String($0) }.joined(separator: ",")
    }

    // MARK: Validation

    private var usesTransport: Bool { kind == .vmess || kind == .vless || kind == .trojan }

    var validationError: String? {
        let host = server.trimmed
        if host.isEmpty { return "Enter the server address." }
        if host.contains(" ") { return "The server address must not contain spaces." }
        guard let portValue = Int(port.trimmed), (1...65535).contains(portValue) else {
            return "Port must be a number between 1 and 65535."
        }

        switch kind {
        case .shadowsocks:
            if method.isEmpty { return "Choose an encryption method." }
            if password.isEmpty && method != "none" { return "Enter the Shadowsocks password." }
        case .vmess:
            if uuid.trimmed.isEmpty { return "Enter the VMess UUID." }
            if Int(alterId.trimmed) == nil { return "Alter ID must be a number." }
        case .vless:
            if uuid.trimmed.isEmpty { return "Enter the VLESS UUID." }
        case .trojan:
            if password.isEmpty { return "Enter the Trojan password." }
        case .socks, .http:
            break
        case .hysteria:
            break
        case .hysteria2:
            if password.isEmpty { return "Enter the Hysteria2 password." }
            if obfsType != "none" && obfsPassword.isEmpty { return "Enter the obfuscation password." }
        case .tuic:
            if uuid.trimmed.isEmpty { return "Enter the TUIC UUID." }
            if password.isEmpty { return "Enter the TUIC password." }
        case .wireguard:
            if privateKey.trimmed.isEmpty { return "Enter the WireGuard private key." }
            if peerPublicKey.trimmed.isEmpty { return "Enter the peer public key." }
            if !mtu.trimmed.isEmpty && Int(mtu.trimmed) == nil { return "MTU must be a number." }
            if !reserved.trimmed.isEmpty && Self.intList(reserved) == nil {
                return "Reserved must be comma separated numbers."
            }
        }

        if usesTransport && transport == .grpc && serviceName.trimmed.isEmpty {
            return "Enter the gRPC service name."
        }
        if !upMbps.trimmed.isEmpty && Int(upMbps.trimmed) == nil { return "Upload Mbps must be a number." }
        if !downMbps.trimmed.isEmpty && Int(downMbps.trimmed) == nil { return "Download Mbps must be a number." }
        return nil
    }

    // MARK: Node

    func makeNode() -> ProxyNode {
        let host = server.trimmed
        let portValue = Int(port.trimmed) ?? 0
        let label = name.trimmed.nonEmpty ?? (host.contains(":") ? "[\(host)]:\(portValue)" : "\(host):\(portValue)")
        var n = ProxyNode(name: label, kind: kind, server: host, port: portValue)
        let usesTLS: Bool

        switch kind {
        case .shadowsocks:
            n.method = method
            n.password = password
            n.plugin = plugin.trimmed.nonEmpty
            n.pluginOpts = pluginOpts.trimmed.nonEmpty
            usesTLS = false
        case .vmess:
            n.uuid = uuid.trimmed
            n.alterId = Int(alterId.trimmed) ?? 0
            n.security = security
            applyTransport(&n)
            usesTLS = tls
        case .vless:
            n.uuid = uuid.trimmed
            n.flow = flow.trimmed.nonEmpty
            applyTransport(&n)
            usesTLS = tls || !realityPublicKey.trimmed.isEmpty
        case .trojan:
            n.password = password
            applyTransport(&n)
            usesTLS = true
        case .socks:
            n.username = username.nonEmpty
            n.password = password.nonEmpty
            usesTLS = false
        case .http:
            n.username = username.nonEmpty
            n.password = password.nonEmpty
            usesTLS = tls
        case .hysteria:
            n.password = password.nonEmpty
            n.obfs = obfs.trimmed.nonEmpty
            n.upMbps = Int(upMbps.trimmed)
            n.downMbps = Int(downMbps.trimmed)
            usesTLS = true
        case .hysteria2:
            n.password = password
            if obfsType != "none" {
                n.obfs = obfsType
                n.obfsPassword = obfsPassword
            }
            n.upMbps = Int(upMbps.trimmed)
            n.downMbps = Int(downMbps.trimmed)
            usesTLS = true
        case .tuic:
            n.uuid = uuid.trimmed
            n.password = password
            n.congestionControl = congestionControl
            n.udpRelayMode = udpRelayMode
            usesTLS = true
        case .wireguard:
            n.privateKey = privateKey.trimmed
            n.peerPublicKey = peerPublicKey.trimmed
            n.preSharedKey = preSharedKey.trimmed.nonEmpty
            n.localAddress = Self.list(localAddress)
            n.mtu = Int(mtu.trimmed)
            n.reserved = Self.intList(reserved) ?? []
            usesTLS = false
        }

        if usesTLS {
            n.tls = true
            n.sni = sni.trimmed.nonEmpty
            n.insecure = insecure
            n.alpn = Self.list(alpn)
            n.fingerprint = fingerprint.trimmed.nonEmpty
            if kind == .vless {
                n.realityPublicKey = realityPublicKey.trimmed.nonEmpty
                n.realityShortID = realityShortID.trimmed.nonEmpty
            }
        }

        n.shareURL = ProxyURLEncoder.encode(n)
        return n
    }

    private func applyTransport(_ n: inout ProxyNode) {
        n.transport = transport
        switch transport {
        case .ws, .http, .httpupgrade:
            n.path = path.trimmed.nonEmpty
            n.host = host.trimmed.nonEmpty
        case .grpc:
            n.serviceName = serviceName.trimmed.nonEmpty
        case .tcp, .quic:
            break
        }
    }

    // MARK: Helpers

    static func list(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func intList(_ text: String) -> [Int]? {
        let parts = list(text)
        let numbers = parts.compactMap { Int($0) }
        return numbers.count == parts.count ? numbers : nil
    }

    static func title(for transport: TransportKind) -> String {
        switch transport {
        case .tcp: return "TCP"
        case .ws: return "WebSocket"
        case .grpc: return "gRPC"
        case .http: return "HTTP/2"
        case .httpupgrade: return "HTTPUpgrade"
        case .quic: return "QUIC"
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
