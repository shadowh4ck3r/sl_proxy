import SwiftUI

/// QR code for the Proxy Share listener so a tethered device can scan its proxy settings.
///
/// The payload is built from `TunnelController.shareAdvertisedAddress` (172.20.10.1 on HOTSPOT,
/// the Wi-Fi or cellular IPv4 otherwise) and the live share port. Formats: the bare `host:port`,
/// an `http://` or `socks5://` URL (with the Proxy Share credentials embedded when set), or the
/// PAC URL served by `PACServer`.
struct ProxyShareQRSheet: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var tunnel: TunnelController
    @Environment(\.dismiss) private var dismiss
    @State private var format: Format = .http

    enum Format: String, CaseIterable, Identifiable {
        case address, http, socks5, pac

        var id: String { rawValue }

        var title: String {
            switch self {
            case .address: return "Address"
            case .http: return "HTTP"
            case .socks5: return "SOCKS5"
            case .pac: return "PAC URL"
            }
        }

        var hint: String {
            switch self {
            case .address: return "Enter this under Wi-Fi > Configure Proxy > Manual (Server and Port)."
            case .http: return "HTTP proxy URL; proxy-aware apps and scanners import it directly."
            case .socks5: return "SOCKS5 URL for apps with a SOCKS setting."
            case .pac: return "Enter this under Wi-Fi > Configure Proxy > Automatic."
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Brand.background
                ScrollView {
                    VStack(spacing: 20) {
                        Picker("Format", selection: $format) {
                            ForEach(Format.allCases) { format in
                                Text(format.title).tag(format)
                            }
                        }
                        .pickerStyle(.segmented)

                        if let payload {
                            code(for: payload)
                            Text(payload)
                                .font(.system(.footnote, design: .monospaced))
                                .multilineTextAlignment(.center)
                                .textSelection(.enabled)
                            Text(format.hint)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            statusLine
                            HStack(spacing: 12) {
                                Button {
                                    UIPasteboard.general.string = payload
                                } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .tint(Brand.orange)
                                ShareLink(item: payload) {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .tint(Brand.orange)
                            }
                        } else {
                            EmptyStateCard(
                                icon: format == .pac ? "doc.text" : "wifi.slash",
                                title: format == .pac ? "PAC is off" : "No address to share",
                                message: unavailableMessage
                            )
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Share Proxy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Pieces

    private func code(for payload: String) -> some View {
        Group {
            if let image = QRCodeGenerator.image(for: payload) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "qrcode")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 280)
        .padding(16)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Brand.gradient, lineWidth: 1)
                .opacity(0.7)
        )
        .shadow(color: Brand.orange.opacity(0.2), radius: 18, y: 8)
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isLive ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text(isLive ? "Listening now" : "Shown from Settings; starts when you connect")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Payload

    private var isLive: Bool {
        switch format {
        case .pac: return tunnel.activePACPort != nil
        default: return tunnel.shareEndpoint != nil
        }
    }

    private var payload: String? {
        guard let host = tunnel.shareAdvertisedAddress else { return nil }
        let port = tunnel.shareAdvertisedPort
        switch format {
        case .address:
            return "\(host):\(port)"
        case .http:
            return "http://\(userInfo)\(host):\(port)"
        case .socks5:
            return "socks5://\(userInfo)\(host):\(port)"
        case .pac:
            return tunnel.pacURL
        }
    }

    /// `user:pass@` when Proxy Share authentication is enforced, otherwise empty.
    private var userInfo: String {
        guard let credentials = settings.value.shareCredentials else { return "" }
        let user = credentials.username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? credentials.username
        let pass = credentials.password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? credentials.password
        return "\(user):\(pass)@"
    }

    private var unavailableMessage: String {
        if format == .pac, tunnel.shareAdvertisedAddress != nil {
            return "Turn on Serve proxy.pac in Proxy Share Settings to get a PAC URL."
        }
        if !settings.value.shareEnabled {
            return "Turn on Share SOCKS5 & HTTP first."
        }
        return "\(settings.value.shareInterface.title) has no IPv4 address right now. Join a network or start Personal Hotspot and try again."
    }
}
