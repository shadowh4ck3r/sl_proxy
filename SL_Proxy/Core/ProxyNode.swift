import Foundation
import SwiftUI

enum ProxyKind: String, Codable, CaseIterable, Identifiable {
    case shadowsocks, vmess, vless, trojan, socks, http, hysteria, hysteria2, tuic, wireguard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shadowsocks: return "Shadowsocks"
        case .vmess: return "VMess"
        case .vless: return "VLESS"
        case .trojan: return "Trojan"
        case .socks: return "SOCKS5"
        case .http: return "HTTP"
        case .hysteria: return "Hysteria"
        case .hysteria2: return "Hysteria2"
        case .tuic: return "TUIC"
        case .wireguard: return "WireGuard"
        }
    }

    var shortTitle: String {
        switch self {
        case .shadowsocks: return "SS"
        case .hysteria2: return "HY2"
        case .hysteria: return "HY"
        case .wireguard: return "WG"
        default: return title.uppercased()
        }
    }
}

enum TransportKind: String, Codable, CaseIterable {
    case tcp, ws, grpc, http, httpupgrade, quic
}

/// A single proxy server. Flat on purpose so every protocol shares one Codable shape.
struct ProxyNode: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var kind: ProxyKind
    var server: String
    var port: Int

    // Credentials
    var uuid: String?
    var password: String?
    var username: String?
    var method: String?
    var security: String?
    var alterId: Int?
    var flow: String?

    // TLS
    var tls = false
    var sni: String?
    var insecure = false
    var alpn: [String] = []
    var fingerprint: String?
    var realityPublicKey: String?
    var realityShortID: String?

    // Transport
    var transport: TransportKind = .tcp
    var path: String?
    var host: String?
    var serviceName: String?

    // Shadowsocks plugin
    var plugin: String?
    var pluginOpts: String?

    // Hysteria / Hysteria2
    var obfs: String?
    var obfsPassword: String?
    var upMbps: Int?
    var downMbps: Int?

    // TUIC
    var congestionControl: String?
    var udpRelayMode: String?

    // WireGuard
    var privateKey: String?
    var peerPublicKey: String?
    var preSharedKey: String?
    var localAddress: [String] = []
    var mtu: Int?
    var reserved: [Int] = []

    // Bookkeeping
    var subscriptionID: UUID?
    var shareURL: String?
    /// Last measured latency in milliseconds; -1 means the test failed.
    var latencyMs: Int?
    /// Purchased proxies (SailorsLoot 24H / 6H lists) stop working at this moment; nil = never.
    var expiresAt: Date?

    init(name: String, kind: ProxyKind, server: String, port: Int) {
        self.name = name
        self.kind = kind
        self.server = server
        self.port = port
    }

    var isExpired: Bool {
        if let expiresAt { return expiresAt < Date() }
        return false
    }

    var displayServer: String {
        server.contains(":") ? "[\(server)]:\(port)" : "\(server):\(port)"
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
