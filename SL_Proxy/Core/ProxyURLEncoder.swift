import Foundation

/// Builds share links for `ProxyNode` values so hand-entered servers can be copied or exported.
/// The output round-trips through `ProxyURLParser`.
enum ProxyURLEncoder {
    static func encode(_ n: ProxyNode) -> String? {
        guard !n.server.isEmpty, n.port > 0 else { return nil }
        switch n.kind {
        case .shadowsocks: return shadowsocks(n)
        case .vmess: return vmess(n)
        case .vless: return vless(n)
        case .trojan: return trojan(n)
        case .socks: return socks(n)
        case .http: return http(n)
        case .hysteria: return hysteria(n)
        case .hysteria2: return hysteria2(n)
        case .tuic: return tuic(n)
        case .wireguard: return wireguard(n)
        }
    }

    // MARK: - Protocols

    /// SIP002: `ss://base64(method:password)@host:port?plugin=…#name`
    private static func shadowsocks(_ n: ProxyNode) -> String {
        let credentials = base64URL("\(n.method ?? "aes-256-gcm"):\(n.password ?? "")")
        var query: [(String, String)] = []
        if let plugin = n.plugin?.nonEmpty {
            let value = [plugin, n.pluginOpts?.nonEmpty].compactMap { $0 }.joined(separator: ";")
            query.append(("plugin", value))
        }
        return url("ss", userInfo: credentials, n, query: query)
    }

    /// v2rayN JSON form: `vmess://base64({"v":"2",…})`
    private static func vmess(_ n: ProxyNode) -> String {
        var object: [String: Any] = [
            "v": "2",
            "ps": n.name,
            "add": n.server,
            "port": String(n.port),
            "id": n.uuid ?? "",
            "aid": String(n.alterId ?? 0),
            "scy": n.security ?? "auto",
            "net": network(n.transport),
            "type": "none",
            "host": n.host ?? "",
            "path": n.transport == .grpc ? (n.serviceName ?? "") : (n.path ?? ""),
            "tls": n.tls ? "tls" : "",
            "sni": n.sni ?? "",
            "fp": n.fingerprint ?? "",
            "alpn": n.alpn.joined(separator: ","),
        ]
        if n.insecure { object["skip-cert-verify"] = "1" }
        let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return "vmess://" + (data?.base64EncodedString() ?? "")
    }

    private static func vless(_ n: ProxyNode) -> String {
        var query = tlsQuery(n, alwaysOn: false)
        if let flow = n.flow?.nonEmpty { query.append(("flow", flow)) }
        query.append(contentsOf: transportQuery(n))
        return url("vless", userInfo: n.uuid ?? "", n, query: query)
    }

    private static func trojan(_ n: ProxyNode) -> String {
        url("trojan", userInfo: n.password ?? "", n, query: tlsQuery(n, alwaysOn: true) + transportQuery(n))
    }

    private static func socks(_ n: ProxyNode) -> String {
        url("socks", userInfo: credentials(n), n, query: [])
    }

    private static func http(_ n: ProxyNode) -> String {
        var query: [(String, String)] = []
        if let sni = n.sni?.nonEmpty { query.append(("sni", sni)) }
        if n.insecure { query.append(("allowInsecure", "1")) }
        return url(n.tls ? "https" : "http", userInfo: credentials(n), n, query: query)
    }

    private static func hysteria(_ n: ProxyNode) -> String {
        var query: [(String, String)] = [("protocol", "udp")]
        if let auth = n.password?.nonEmpty { query.append(("auth", auth)) }
        if let sni = n.sni?.nonEmpty { query.append(("peer", sni)) }
        if n.insecure { query.append(("insecure", "1")) }
        query.append(("upmbps", String(n.upMbps ?? 100)))
        query.append(("downmbps", String(n.downMbps ?? 100)))
        if let obfs = n.obfs?.nonEmpty { query.append(("obfsParam", obfs)) }
        if !n.alpn.isEmpty { query.append(("alpn", n.alpn.joined(separator: ","))) }
        return url("hysteria", userInfo: nil, n, query: query)
    }

    private static func hysteria2(_ n: ProxyNode) -> String {
        var query: [(String, String)] = []
        if let sni = n.sni?.nonEmpty { query.append(("sni", sni)) }
        if n.insecure { query.append(("insecure", "1")) }
        if let obfs = n.obfs?.nonEmpty {
            query.append(("obfs", obfs))
            query.append(("obfs-password", n.obfsPassword ?? ""))
        }
        if let up = n.upMbps { query.append(("up", String(up))) }
        if let down = n.downMbps { query.append(("down", String(down))) }
        if !n.alpn.isEmpty { query.append(("alpn", n.alpn.joined(separator: ","))) }
        if let fp = n.fingerprint?.nonEmpty { query.append(("fp", fp)) }
        return url("hysteria2", userInfo: n.password ?? "", n, query: query)
    }

    private static func tuic(_ n: ProxyNode) -> String {
        var query: [(String, String)] = []
        if let sni = n.sni?.nonEmpty { query.append(("sni", sni)) }
        query.append(("alpn", (n.alpn.isEmpty ? ["h3"] : n.alpn).joined(separator: ",")))
        query.append(("congestion_control", n.congestionControl ?? "cubic"))
        query.append(("udp_relay_mode", n.udpRelayMode ?? "native"))
        if n.insecure { query.append(("allow_insecure", "1")) }
        return url("tuic", userInfo: "\(n.uuid ?? ""):\(n.password ?? "")", n, query: query)
    }

    private static func wireguard(_ n: ProxyNode) -> String {
        var query: [(String, String)] = [("publickey", n.peerPublicKey ?? "")]
        if let psk = n.preSharedKey?.nonEmpty { query.append(("presharedkey", psk)) }
        if !n.localAddress.isEmpty { query.append(("address", n.localAddress.joined(separator: ","))) }
        if let mtu = n.mtu { query.append(("mtu", String(mtu))) }
        if !n.reserved.isEmpty { query.append(("reserved", n.reserved.map { String($0) }.joined(separator: ","))) }
        return url("wireguard", userInfo: n.privateKey ?? "", n, query: query)
    }

    // MARK: - Helpers

    private static func credentials(_ n: ProxyNode) -> String? {
        guard n.username?.nonEmpty != nil || n.password?.nonEmpty != nil else { return nil }
        return "\(n.username ?? ""):\(n.password ?? "")"
    }

    private static func tlsQuery(_ n: ProxyNode, alwaysOn: Bool) -> [(String, String)] {
        var q: [(String, String)] = []
        if let pbk = n.realityPublicKey?.nonEmpty {
            q.append(("security", "reality"))
            q.append(("pbk", pbk))
            if let sid = n.realityShortID?.nonEmpty { q.append(("sid", sid)) }
        } else if n.tls || alwaysOn {
            q.append(("security", "tls"))
        } else {
            q.append(("security", "none"))
        }
        guard n.tls || alwaysOn || n.realityPublicKey?.nonEmpty != nil else { return q }
        if let sni = n.sni?.nonEmpty { q.append(("sni", sni)) }
        if let fp = n.fingerprint?.nonEmpty { q.append(("fp", fp)) }
        if !n.alpn.isEmpty { q.append(("alpn", n.alpn.joined(separator: ","))) }
        if n.insecure { q.append(("allowInsecure", "1")) }
        return q
    }

    private static func transportQuery(_ n: ProxyNode) -> [(String, String)] {
        var q: [(String, String)] = [("type", network(n.transport))]
        switch n.transport {
        case .tcp, .quic:
            break
        case .ws, .http, .httpupgrade:
            if let host = n.host?.nonEmpty { q.append(("host", host)) }
            if let path = n.path?.nonEmpty { q.append(("path", path)) }
        case .grpc:
            if let service = n.serviceName?.nonEmpty { q.append(("serviceName", service)) }
        }
        return q
    }

    private static func network(_ transport: TransportKind) -> String {
        switch transport {
        case .tcp: return "tcp"
        case .ws: return "ws"
        case .grpc: return "grpc"
        case .http: return "http"
        case .httpupgrade: return "httpupgrade"
        case .quic: return "quic"
        }
    }

    private static func url(_ scheme: String, userInfo: String?, _ n: ProxyNode, query: [(String, String)]) -> String {
        var result = scheme + "://"
        if let userInfo, !userInfo.isEmpty {
            result += percent(userInfo, allowing: ":") + "@"
        }
        result += n.server.contains(":") ? "[\(n.server)]" : n.server
        result += ":\(n.port)"
        let pairs = query.filter { !$0.1.isEmpty }.map { "\($0.0)=\(percent($0.1))" }
        if !pairs.isEmpty { result += "?" + pairs.joined(separator: "&") }
        if !n.name.isEmpty { result += "#" + percent(n.name) }
        return result
    }

    private static func percent(_ text: String, allowing extra: String = "") -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~" + extra)
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    private static func base64URL(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
