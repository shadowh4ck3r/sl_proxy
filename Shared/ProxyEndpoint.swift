import Foundation

/// Host, port and credentials pulled out of a share link (ss://, vmess://, vless://, trojan://,
/// socks://, http://, hysteria2://, tuic://) or a sing-box JSON config. Never throws: a nil
/// result means "not a usable proxy config". Compiled into both the app and the tunnel extension.
struct ProxyEndpoint: Equatable {
    let scheme: String
    let host: String
    let port: Int
    /// Username, or the cipher method for Shadowsocks.
    let username: String?
    /// Password, or the UUID for VMess / VLESS / TUIC.
    let secret: String?

    var label: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }

    static func parse(_ raw: String) -> ProxyEndpoint? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return text.hasPrefix("{") ? fromSingBoxJSON(text) : fromShareLink(text)
    }

    // MARK: - sing-box JSON (what SingBoxConfigBuilder generates)

    private static func fromSingBoxJSON(_ text: String) -> ProxyEndpoint? {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outbounds = root["outbounds"] as? [[String: Any]],
              let proxy = outbounds.first(where: { ($0["server"] as? String)?.isEmpty == false }),
              let host = proxy["server"] as? String,
              let port = intValue(proxy["server_port"]), validPort(port)
        else { return nil }
        return ProxyEndpoint(
            scheme: proxy["type"] as? String ?? "unknown",
            host: host,
            port: port,
            username: (proxy["username"] as? String) ?? (proxy["method"] as? String),
            secret: (proxy["password"] as? String) ?? (proxy["uuid"] as? String)
        )
    }

    // MARK: - Share links

    private static func fromShareLink(_ text: String) -> ProxyEndpoint? {
        guard let schemeEnd = text.range(of: "://") else { return nil }
        let scheme = text[..<schemeEnd.lowerBound].lowercased()
        var body = String(text[schemeEnd.upperBound...])
        if let hash = body.firstIndex(of: "#") { body = String(body[..<hash]) }
        if let query = body.firstIndex(of: "?") { body = String(body[..<query]) }
        if let slash = body.firstIndex(of: "/") { body = String(body[..<slash]) }

        // vmess://BASE64({"add":..,"port":..,"id":..})
        if scheme == "vmess", let json = base64Decode(body), let data = json.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let host = object["add"] as? String, let port = intValue(object["port"]), validPort(port) {
            return ProxyEndpoint(scheme: scheme, host: host, port: port, username: nil, secret: object["id"] as? String)
        }

        var userInfo: String?
        var authority = body
        if let at = body.lastIndex(of: "@") {
            userInfo = String(body[..<at]).removingPercentEncoding
            authority = String(body[body.index(after: at)...])
        } else if scheme == "ss", let decoded = base64Decode(body), let at = decoded.lastIndex(of: "@") {
            // Legacy ss://BASE64(method:password@host:port)
            userInfo = String(decoded[..<at])
            authority = String(decoded[decoded.index(after: at)...])
        }

        guard let endpoint = splitHostPort(authority), validPort(endpoint.port) else { return nil }

        var username: String?
        var secret: String?
        if var info = userInfo, !info.isEmpty {
            if scheme == "ss", !info.contains(":"), let decoded = base64Decode(info) { info = decoded }
            let parts = info.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                username = parts[0]
                secret = parts[1]
            } else {
                secret = parts.first
            }
        }
        return ProxyEndpoint(scheme: scheme, host: endpoint.host, port: endpoint.port, username: username, secret: secret)
    }

    // MARK: - Helpers

    private static func splitHostPort(_ text: String) -> (host: String, port: Int)? {
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            let host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()) else { return nil }
            return (host, port)
        }
        guard let colon = text.lastIndex(of: ":"), let port = Int(text[text.index(after: colon)...]) else { return nil }
        let host = String(text[..<colon])
        return host.isEmpty ? nil : (host, port)
    }

    private static func validPort(_ port: Int) -> Bool { (1...65535).contains(port) }

    private static func intValue(_ any: Any?) -> Int? {
        switch any {
        case let number as NSNumber: return number.intValue
        case let string as String: return Int(string.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    private static func base64Decode(_ text: String) -> String? {
        var padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded += "=" }
        guard let data = Data(base64Encoded: padded) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
