import Foundation

/// Builds a v2ray / Xray style JSON config for one server ("Copy v2ray JSON" in the Share sheet).
/// The result has a local SOCKS (10808) and HTTP (10809) inbound and the server as the `proxy`
/// outbound, so it opens directly in v2rayN, v2rayNG and other Xray based clients.
///
/// Xray has no Hysteria, Hysteria2, TUIC or WireGuard-over-share-link outbound, so `config(for:)`
/// returns nil for those protocols.
enum V2RayJSON {
    static func config(for node: ProxyNode) -> String? {
        guard let outbound = outbound(for: node) else { return nil }
        let root: [String: Any] = [
            "log": ["loglevel": "warning"],
            "inbounds": [
                ["tag": "socks-in", "listen": "127.0.0.1", "port": 10808, "protocol": "socks",
                 "settings": ["udp": true]],
                ["tag": "http-in", "listen": "127.0.0.1", "port": 10809, "protocol": "http"],
            ],
            "outbounds": [
                outbound,
                ["tag": "direct", "protocol": "freedom"],
                ["tag": "block", "protocol": "blackhole"],
            ],
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func outbound(for node: ProxyNode) -> [String: Any]? {
        var out: [String: Any] = ["tag": "proxy"]
        switch node.kind {
        case .vmess:
            guard let id = node.uuid else { return nil }
            out["protocol"] = "vmess"
            out["settings"] = ["vnext": [[
                "address": node.server, "port": node.port,
                "users": [["id": id, "alterId": node.alterId ?? 0, "security": node.security ?? "auto"]],
            ]]]
        case .vless:
            guard let id = node.uuid else { return nil }
            var user: [String: Any] = ["id": id, "encryption": "none"]
            if let flow = node.flow, !flow.isEmpty { user["flow"] = flow }
            out["protocol"] = "vless"
            out["settings"] = ["vnext": [["address": node.server, "port": node.port, "users": [user]]]]
        case .trojan:
            guard let password = node.password else { return nil }
            out["protocol"] = "trojan"
            out["settings"] = ["servers": [["address": node.server, "port": node.port, "password": password]]]
        case .shadowsocks:
            guard let method = node.method, let password = node.password else { return nil }
            out["protocol"] = "shadowsocks"
            out["settings"] = ["servers": [[
                "address": node.server, "port": node.port, "method": method, "password": password,
            ]]]
        case .socks, .http:
            var server: [String: Any] = ["address": node.server, "port": node.port]
            if let user = node.username, !user.isEmpty {
                server["users"] = [["user": user, "pass": node.password ?? ""]]
            }
            out["protocol"] = node.kind == .socks ? "socks" : "http"
            out["settings"] = ["servers": [server]]
            return out
        case .hysteria, .hysteria2, .tuic, .wireguard:
            return nil
        }
        out["streamSettings"] = streamSettings(for: node)
        return out
    }

    private static func streamSettings(for node: ProxyNode) -> [String: Any] {
        var stream: [String: Any] = [:]
        switch node.transport {
        case .tcp:
            stream["network"] = "tcp"
        case .ws:
            stream["network"] = "ws"
            var ws: [String: Any] = ["path": node.path ?? "/"]
            if let host = node.host, !host.isEmpty { ws["headers"] = ["Host": host] }
            stream["wsSettings"] = ws
        case .grpc:
            stream["network"] = "grpc"
            stream["grpcSettings"] = ["serviceName": node.serviceName ?? ""]
        case .http:
            stream["network"] = "h2"
            var h2: [String: Any] = ["path": node.path ?? "/"]
            if let host = node.host, !host.isEmpty { h2["host"] = [host] }
            stream["httpSettings"] = h2
        case .httpupgrade:
            stream["network"] = "httpupgrade"
            var upgrade: [String: Any] = ["path": node.path ?? "/"]
            if let host = node.host, !host.isEmpty { upgrade["host"] = host }
            stream["httpupgradeSettings"] = upgrade
        case .quic:
            stream["network"] = "quic"
        }
        if let publicKey = node.realityPublicKey, !publicKey.isEmpty {
            stream["security"] = "reality"
            var reality: [String: Any] = [
                "serverName": node.sni ?? node.server,
                "publicKey": publicKey,
                "fingerprint": node.fingerprint ?? "chrome",
            ]
            if let shortID = node.realityShortID { reality["shortId"] = shortID }
            stream["realitySettings"] = reality
        } else if node.tls {
            stream["security"] = "tls"
            var tls: [String: Any] = ["serverName": node.sni ?? node.host ?? node.server, "allowInsecure": node.insecure]
            if !node.alpn.isEmpty { tls["alpn"] = node.alpn }
            if let fingerprint = node.fingerprint, !fingerprint.isEmpty { tls["fingerprint"] = fingerprint }
            stream["tlsSettings"] = tls
        } else {
            stream["security"] = "none"
        }
        return stream
    }
}
