import Foundation

enum ProxyParseError: LocalizedError {
    case unsupportedScheme(String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedScheme(let scheme): return "Unsupported link type \"\(scheme)://\""
        case .malformed(let reason): return reason
        }
    }
}

/// Minimal URL splitter that tolerates the non-standard characters found in proxy share links.
struct RawProxyURL {
    let scheme: String
    let userInfo: String?
    let host: String
    let port: Int?
    let query: [String: String]
    let fragment: String?
    /// Everything between `scheme://` and the first `?` or `#` (used by legacy Base64 forms).
    let opaque: String

    init?(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let schemeRange = text.range(of: "://") else { return nil }
        scheme = text[..<schemeRange.lowerBound].lowercased()
        var rest = String(text[schemeRange.upperBound...])

        if let hash = rest.firstIndex(of: "#") {
            let fragmentText = String(rest[rest.index(after: hash)...])
            fragment = (fragmentText.removingPercentEncoding ?? fragmentText).nonEmpty
            rest = String(rest[..<hash])
        } else {
            fragment = nil
        }

        var query: [String: String] = [:]
        if let question = rest.firstIndex(of: "?") {
            let queryText = rest[rest.index(after: question)...]
            rest = String(rest[..<question])
            for pair in queryText.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard let key = parts.first, !key.isEmpty else { continue }
                let value = parts.count > 1 ? parts[1] : ""
                query[key.removingPercentEncoding ?? key] = value.removingPercentEncoding ?? value
            }
        }
        self.query = query
        opaque = rest

        var authority = rest
        if let slash = authority.firstIndex(of: "/") {
            authority = String(authority[..<slash])
        }
        if let at = authority.lastIndex(of: "@") {
            let info = String(authority[..<at])
            userInfo = info.removingPercentEncoding ?? info
            authority = String(authority[authority.index(after: at)...])
        } else {
            userInfo = nil
        }
        let endpoint = RawProxyURL.hostPort(authority)
        host = endpoint.host
        port = endpoint.port
    }

    /// Splits `host:port` while keeping bracketed IPv6 literals intact.
    static func hostPort(_ text: String) -> (host: String, port: Int?) {
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            let host = String(text[text.index(after: text.startIndex)..<close])
            let remainder = text[text.index(after: close)...]
            let port = remainder.hasPrefix(":") ? Int(remainder.dropFirst()) : nil
            return (host, port)
        }
        if let colon = text.lastIndex(of: ":"), text.filter({ $0 == ":" }).count == 1 {
            return (String(text[..<colon]), Int(text[text.index(after: colon)...]))
        }
        return (text, nil)
    }

    var endpointLabel: String {
        port.map { "\(host):\($0)" } ?? host
    }
}

/// Converts share links into `ProxyNode` values.
enum ProxyURLParser {
    static let supportedSchemes: [String] = [
        "ss", "vmess", "vless", "trojan", "socks", "socks5", "socks5h", "http", "https",
        "hysteria", "hysteria2", "hy2", "tuic", "wireguard", "wg",
    ]

    static func parse(_ raw: String) throws -> ProxyNode {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = RawProxyURL(text) else { throw ProxyParseError.malformed("Not a proxy link") }
        var node: ProxyNode
        switch url.scheme {
        case "ss": node = try shadowsocks(url)
        case "vmess": node = try vmess(url)
        case "vless": node = try vless(url)
        case "trojan": node = try trojan(url)
        case "socks", "socks5", "socks5h": node = try socks(url)
        case "http", "https": node = try http(url)
        case "hysteria2", "hy2": node = try hysteria2(url)
        case "hysteria": node = try hysteria(url)
        case "tuic": node = try tuic(url)
        case "wireguard", "wg": node = try wireguard(url)
        default: throw ProxyParseError.unsupportedScheme(url.scheme)
        }
        node.shareURL = text
        return node
    }

    /// Parses free text: one link per line, or a Base64 encoded list of links (subscription body).
    static func parseMany(_ text: String) -> (nodes: [ProxyNode], failures: [String]) {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.contains("://"), let decoded = Base64Codec.decodeToString(body), decoded.contains("://") {
            body = decoded
        }
        var nodes: [ProxyNode] = []
        var failures: [String] = []
        for line in body.components(separatedBy: .newlines) {
            let candidate = line.trimmingCharacters(in: .whitespaces)
            guard candidate.contains("://") else { continue }
            do {
                nodes.append(try parse(candidate))
            } catch {
                failures.append("\(candidate.prefix(28))…: \(error.localizedDescription)")
            }
        }
        return (nodes, failures)
    }

    // MARK: - Protocols

    private static func shadowsocks(_ u: RawProxyURL) throws -> ProxyNode {
        var host = u.host
        var port = u.port
        var method = ""
        var password = ""

        if let userInfo = u.userInfo, !userInfo.isEmpty {
            // SIP002: plain `method:password` or Base64(method:password)
            let credentials = userInfo.contains(":") ? userInfo : (Base64Codec.decodeToString(userInfo) ?? userInfo)
            (method, password) = try splitFirst(credentials, ":", error: "Shadowsocks link is missing the method or password")
        } else {
            // Legacy: Base64(method:password@host:port)
            guard let decoded = Base64Codec.decodeToString(u.opaque), let at = decoded.lastIndex(of: "@") else {
                throw ProxyParseError.malformed("Unrecognised Shadowsocks link")
            }
            (method, password) = try splitFirst(String(decoded[..<at]), ":", error: "Shadowsocks link is missing the method or password")
            let endpoint = RawProxyURL.hostPort(String(decoded[decoded.index(after: at)...]))
            host = endpoint.host
            port = endpoint.port
        }

        guard let port, !host.isEmpty else { throw ProxyParseError.malformed("Shadowsocks link is missing the server or port") }
        var node = ProxyNode(name: u.fragment ?? "\(host):\(port)", kind: .shadowsocks, server: host, port: port)
        node.method = method
        node.password = password
        if let plugin = u.query["plugin"]?.nonEmpty {
            let parts = plugin.split(separator: ";", maxSplits: 1).map(String.init)
            let name = parts[0]
            node.plugin = (name == "simple-obfs" || name == "obfs") ? "obfs-local" : name
            node.pluginOpts = parts.count > 1 ? parts[1] : nil
        }
        return node
    }

    private static func vmess(_ u: RawProxyURL) throws -> ProxyNode {
        if let data = Base64Codec.decode(u.opaque),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let fields = JSONFields(object)
            guard let host = fields.string("add")?.nonEmpty, let port = fields.int("port"), let id = fields.string("id")?.nonEmpty else {
                throw ProxyParseError.malformed("VMess link is missing the server, port or id")
            }
            var node = ProxyNode(name: fields.string("ps")?.nonEmpty ?? "\(host):\(port)", kind: .vmess, server: host, port: port)
            node.uuid = id
            node.alterId = fields.int("aid") ?? 0
            node.security = fields.string("scy")?.nonEmpty ?? fields.string("security")?.nonEmpty ?? "auto"
            let tlsValue = (fields.string("tls") ?? "").lowercased()
            node.tls = tlsValue == "tls" || tlsValue == "1" || tlsValue == "true"
            node.sni = fields.string("sni")?.nonEmpty
            node.fingerprint = fields.string("fp")?.nonEmpty
            if let alpn = fields.string("alpn")?.nonEmpty { node.alpn = splitList(alpn) }
            node.insecure = flag(fields.string("skip-cert-verify")) || flag(fields.string("allowInsecure"))
            let net = (fields.string("net") ?? "tcp").lowercased()
            let headerType = (fields.string("type") ?? "none").lowercased()
            node.transport = try transportKind(net: net, headerType: headerType)
            node.host = fields.string("host")?.nonEmpty
            node.path = fields.string("path")?.nonEmpty
            if node.transport == .grpc {
                node.serviceName = fields.string("serviceName")?.nonEmpty ?? fields.string("path")?.nonEmpty
            }
            return node
        }

        // Standard URL form: vmess://uuid@host:port?…
        guard let uuid = u.userInfo?.nonEmpty, let port = u.port else {
            throw ProxyParseError.malformed("Unrecognised VMess link")
        }
        var node = ProxyNode(name: u.fragment ?? u.endpointLabel, kind: .vmess, server: u.host, port: port)
        node.uuid = uuid
        node.security = u.query["encryption"]?.nonEmpty ?? "auto"
        node.alterId = 0
        applyTLS(&node, u, alwaysOn: false)
        try applyTransport(&node, u)
        return node
    }

    private static func vless(_ u: RawProxyURL) throws -> ProxyNode {
        guard let uuid = u.userInfo?.nonEmpty, let port = u.port, !u.host.isEmpty else {
            throw ProxyParseError.malformed("VLESS link is missing the id, server or port")
        }
        var node = ProxyNode(name: u.fragment ?? u.endpointLabel, kind: .vless, server: u.host, port: port)
        node.uuid = uuid
        node.flow = u.query["flow"]?.nonEmpty
        applyTLS(&node, u, alwaysOn: false)
        try applyTransport(&node, u)
        return node
    }

    private static func trojan(_ u: RawProxyURL) throws -> ProxyNode {
        guard let password = u.userInfo?.nonEmpty, let port = u.port, !u.host.isEmpty else {
            throw ProxyParseError.malformed("Trojan link is missing the password, server or port")
        }
        var node = ProxyNode(name: u.fragment ?? u.endpointLabel, kind: .trojan, server: u.host, port: port)
        node.password = password
        applyTLS(&node, u, alwaysOn: true)
        try applyTransport(&node, u)
        return node
    }

    private static func socks(_ u: RawProxyURL) throws -> ProxyNode {
        var host = u.host
        var port = u.port
        var username: String?
        var password: String?

        if let userInfo = u.userInfo?.nonEmpty {
            let credentials = userInfo.contains(":") ? userInfo : (Base64Codec.decodeToString(userInfo) ?? userInfo)
            let parts = credentials.split(separator: ":", maxSplits: 1).map(String.init)
            username = parts.first?.nonEmpty
            password = parts.count > 1 ? parts[1] : nil
        } else if let decoded = Base64Codec.decodeToString(u.opaque), let at = decoded.lastIndex(of: "@") {
            let parts = decoded[..<at].split(separator: ":", maxSplits: 1).map(String.init)
            username = parts.first?.nonEmpty
            password = parts.count > 1 ? parts[1] : nil
            let endpoint = RawProxyURL.hostPort(String(decoded[decoded.index(after: at)...]))
            host = endpoint.host
            port = endpoint.port
        }

        guard let port, !host.isEmpty else { throw ProxyParseError.malformed("SOCKS link is missing the server or port") }
        var node = ProxyNode(name: u.fragment ?? "\(host):\(port)", kind: .socks, server: host, port: port)
        node.username = username
        node.password = password
        return node
    }

    private static func http(_ u: RawProxyURL) throws -> ProxyNode {
        guard let port = u.port, !u.host.isEmpty else {
            throw ProxyParseError.malformed("HTTP proxy link is missing the server or port")
        }
        var node = ProxyNode(name: u.fragment ?? u.endpointLabel, kind: .http, server: u.host, port: port)
        if let userInfo = u.userInfo?.nonEmpty {
            let parts = userInfo.split(separator: ":", maxSplits: 1).map(String.init)
            node.username = parts.first?.nonEmpty
            node.password = parts.count > 1 ? parts[1] : nil
        }
        node.tls = u.scheme == "https"
        node.sni = u.query["sni"]?.nonEmpty
        node.insecure = flag(u.query["allowInsecure"]) || flag(u.query["insecure"])
        return node
    }

    private static func hysteria2(_ u: RawProxyURL) throws -> ProxyNode {
        guard let port = u.port, !u.host.isEmpty else {
            throw ProxyParseError.malformed("Hysteria2 link is missing the server or port")
        }
        var node = ProxyNode(name: u.fragment ?? u.endpointLabel, kind: .hysteria2, server: u.host, port: port)
        node.password = u.userInfo ?? ""
        node.tls = true
        node.sni = u.query["sni"]?.nonEmpty ?? u.query["peer"]?.nonEmpty
        node.insecure = flag(u.query["insecure"]) || flag(u.query["allowInsecure"])
        if let alpn = u.query["alpn"]?.nonEmpty { node.alpn = splitList(alpn) }
        node.fingerprint = u.query["fp"]?.nonEmpty
        if let obfs = u.query["obfs"]?.nonEmpty, obfs.lowercased() != "none" {
            node.obfs = obfs
            node.obfsPassword = u.query["obfs-password"]?.nonEmpty ?? u.query["obfsParam"]?.nonEmpty
        }
        node.upMbps = leadingInt(u.query["up"] ?? u.query["upmbps"])
        node.downMbps = leadingInt(u.query["down"] ?? u.query["downmbps"])
        return node
    }

    private static func hysteria(_ u: RawProxyURL) throws -> ProxyNode {
        guard let port = u.port, !u.host.isEmpty else {
            throw ProxyParseError.malformed("Hysteria link is missing the server or port")
        }
        var node = ProxyNode(name: u.fragment ?? u.endpointLabel, kind: .hysteria, server: u.host, port: port)
        node.password = u.query["auth"]?.nonEmpty ?? u.query["auth_str"]?.nonEmpty ?? u.userInfo
        node.tls = true
        node.sni = u.query["peer"]?.nonEmpty ?? u.query["sni"]?.nonEmpty
        node.insecure = flag(u.query["insecure"]) || flag(u.query["allowInsecure"])
        if let alpn = u.query["alpn"]?.nonEmpty { node.alpn = splitList(alpn) }
        node.obfs = u.query["obfs"]?.nonEmpty ?? u.query["obfsParam"]?.nonEmpty
        node.upMbps = leadingInt(u.query["upmbps"] ?? u.query["up"]) ?? 100
        node.downMbps = leadingInt(u.query["downmbps"] ?? u.query["down"]) ?? 100
        return node
    }

    private static func tuic(_ u: RawProxyURL) throws -> ProxyNode {
        guard let userInfo = u.userInfo?.nonEmpty, let port = u.port, !u.host.isEmpty else {
            throw ProxyParseError.malformed("TUIC link is missing the uuid, server or port")
        }
        let parts = userInfo.split(separator: ":", maxSplits: 1).map(String.init)
        var node = ProxyNode(name: u.fragment ?? u.endpointLabel, kind: .tuic, server: u.host, port: port)
        node.uuid = parts[0]
        node.password = parts.count > 1 ? parts[1] : (u.query["password"] ?? "")
        node.tls = true
        node.sni = u.query["sni"]?.nonEmpty ?? u.query["peer"]?.nonEmpty
        node.insecure = flag(u.query["allow_insecure"]) || flag(u.query["allowInsecure"]) || flag(u.query["insecure"])
        node.alpn = splitList(u.query["alpn"] ?? "h3")
        node.congestionControl = u.query["congestion_control"]?.nonEmpty ?? u.query["congestion"]?.nonEmpty
        node.udpRelayMode = u.query["udp_relay_mode"]?.nonEmpty
        return node
    }

    private static func wireguard(_ u: RawProxyURL) throws -> ProxyNode {
        guard let privateKey = u.userInfo?.nonEmpty ?? u.query["privatekey"]?.nonEmpty ?? u.query["private_key"]?.nonEmpty,
              let port = u.port, !u.host.isEmpty else {
            throw ProxyParseError.malformed("WireGuard link is missing the private key, server or port")
        }
        guard let peerKey = u.query["publickey"]?.nonEmpty ?? u.query["public_key"]?.nonEmpty ?? u.query["pubkey"]?.nonEmpty ?? u.query["peer_public_key"]?.nonEmpty else {
            throw ProxyParseError.malformed("WireGuard link is missing the peer public key")
        }
        var node = ProxyNode(name: u.fragment ?? u.endpointLabel, kind: .wireguard, server: u.host, port: port)
        node.privateKey = privateKey
        node.peerPublicKey = peerKey
        node.preSharedKey = u.query["presharedkey"]?.nonEmpty ?? u.query["preshared_key"]?.nonEmpty ?? u.query["psk"]?.nonEmpty
        node.localAddress = splitList(u.query["address"] ?? u.query["ip"] ?? "")
        node.mtu = Int(u.query["mtu"] ?? "")
        node.reserved = splitList(u.query["reserved"] ?? "").compactMap { Int($0) }
        return node
    }

    // MARK: - Shared helpers

    private static func applyTLS(_ node: inout ProxyNode, _ u: RawProxyURL, alwaysOn: Bool) {
        let security = (u.query["security"] ?? "").lowercased()
        if alwaysOn {
            node.tls = security != "none"
        } else {
            node.tls = security == "tls" || security == "reality" || security == "xtls"
        }
        node.sni = u.query["sni"]?.nonEmpty ?? u.query["peer"]?.nonEmpty
        node.fingerprint = u.query["fp"]?.nonEmpty
        if let alpn = u.query["alpn"]?.nonEmpty { node.alpn = splitList(alpn) }
        node.insecure = flag(u.query["allowInsecure"]) || flag(u.query["insecure"]) || flag(u.query["allow_insecure"])
        if security == "reality" {
            node.realityPublicKey = u.query["pbk"]?.nonEmpty
            node.realityShortID = u.query["sid"]?.nonEmpty
        }
    }

    private static func applyTransport(_ node: inout ProxyNode, _ u: RawProxyURL) throws {
        let net = (u.query["type"] ?? u.query["net"] ?? "tcp").lowercased()
        let headerType = (u.query["headerType"] ?? "none").lowercased()
        node.transport = try transportKind(net: net, headerType: headerType)
        node.host = u.query["host"]?.nonEmpty
        node.path = u.query["path"]?.nonEmpty
        if node.transport == .grpc {
            node.serviceName = u.query["serviceName"]?.nonEmpty ?? u.query["path"]?.nonEmpty
        }
    }

    private static func transportKind(net: String, headerType: String) throws -> TransportKind {
        switch net {
        case "tcp", "", "none": return headerType == "http" ? .http : .tcp
        case "ws", "websocket": return .ws
        case "grpc", "gun": return .grpc
        case "h2", "http": return .http
        case "httpupgrade": return .httpupgrade
        case "quic": return .quic
        default: throw ProxyParseError.malformed("Transport \"\(net)\" is not supported")
        }
    }

    private static func splitFirst(_ text: String, _ separator: Character, error: String) throws -> (String, String) {
        guard let index = text.firstIndex(of: separator) else { throw ProxyParseError.malformed(error) }
        return (String(text[..<index]), String(text[text.index(after: index)...]))
    }

    private static func splitList(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func flag(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["1", "true", "yes", "on"].contains(value.lowercased())
    }

    private static func leadingInt(_ value: String?) -> Int? {
        guard let value else { return nil }
        let digits = value.prefix { $0.isNumber }
        return Int(digits)
    }
}

/// Tolerant accessor for loosely typed JSON (VMess links mix strings and numbers).
struct JSONFields {
    let object: [String: Any]

    init(_ object: [String: Any]) { self.object = object }

    func string(_ key: String) -> String? {
        switch object[key] {
        case let value as String: return value
        case let value as NSNumber: return value.stringValue
        default: return nil
        }
    }

    func int(_ key: String) -> Int? {
        switch object[key] {
        case let value as NSNumber: return value.intValue
        case let value as String: return Int(value.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }
}
