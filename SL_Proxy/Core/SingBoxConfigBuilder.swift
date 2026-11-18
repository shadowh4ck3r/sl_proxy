import Foundation
import Network

/// Turns the selected node and user settings into a sing-box 1.11 JSON configuration.
enum SingBoxConfigBuilder {
    static let proxyTag = "proxy"
    static let directTag = "direct"
    /// Tag of the urltest outbound group used when Auto Node Switching is on.
    static let urlTestGroupTag = "auto"

    private static let geositeBase = "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/"
    private static let geoipBase = "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/"

    /// Where sing-box accepts traffic from.
    enum Inbound: Equatable {
        /// System-wide TUN device (Network Extension build on `main`).
        case tun
        /// HTTP + SOCKS5 ("mixed") listener bound to loopback (user-space build).
        case loopback(host: String, port: Int)

        /// The in-app engine's listener: 127.0.0.1 on the port chosen in Settings (default 20080,
        /// never 1080 so it cannot collide with other proxy tools on the device).
        static func localProxy(_ settings: AppSettings) -> Inbound {
            .loopback(host: AppSettings.localProxyHost, port: settings.effectiveLocalProxyPort)
        }
    }

    /// Tag of the optional Proxy Share listener (second mixed inbound).
    static let shareInboundTag = "share-in"

    /// Address the Proxy Share listener binds to, honouring the CELLULAR / WIFI / HOTSPOT picker.
    /// iOS does not let an app pin sockets to an interface, so binding the listener to that
    /// interface's address is the supported way to put the shared inbound on that network.
    ///
    /// - WIFI / CELLULAR: the IPv4 address of `en0` / `pdp_ip0`. Nil when sharing is off or the
    ///   interface has no address right now (Wi-Fi off, no cellular data), in which case only the
    ///   loopback listener is configured.
    /// - HOTSPOT: never nil while sharing is on; see `hotspotListenAddress`.
    static func shareListenAddress(_ settings: AppSettings) -> String? {
        guard settings.shareEnabled else { return nil }
        switch settings.shareInterface {
        case .hotspot:
            return hotspotListenAddress()
        case .wifi, .cellular:
            return NetworkInterfaces.ipv4Address(of: settings.shareInterface)
        }
    }

    /// Listen address for the HOTSPOT interface: the `bridge100` gateway (172.20.10.1) while
    /// Personal Hotspot is up, otherwise the wildcard 0.0.0.0. iOS only creates bridge100 once a
    /// client tethers, and binding 172.20.10.1 before that fails with "can't assign requested
    /// address", so the wildcard keeps the shared inbound reachable at 172.20.10.1:<port> the
    /// moment the bridge comes up and hotspot clients route straight through the core.
    static func hotspotListenAddress() -> String {
        NetworkInterfaces.ipv4Address(of: .hotspot) ?? ShareInterface.wildcardAddress
    }

    /// Second mixed inbound for Proxy Share, or nil (see `shareListenAddress`). With Proxy Share
    /// authentication on, the `users` list makes sing-box require the username and password on
    /// both HTTP (Basic) and SOCKS5 (username/password) connections to this listener only.
    private static func shareInbound(_ settings: AppSettings) -> [String: Any]? {
        guard let host = shareListenAddress(settings) else { return nil }
        var inbound = mixedInbound(host: host, port: settings.effectiveSharePort)
        inbound["tag"] = shareInboundTag
        if let credentials = settings.shareCredentials {
            inbound["users"] = [["username": credentials.username, "password": credentials.password]]
        }
        return inbound
    }

    /// `inbound` defaults to the loopback mixed listener on the port taken from `settings`. In the
    /// user-space build the Proxy Share listener is added when it is enabled (`shareInbound`).
    /// When `allNodes` has ≥2 entries and `settings.autoNodeSwitching` is on, a urltest outbound
    /// group is emitted and the route final is pointed at it instead of the single proxy tag.
    static func build(node: ProxyNode, settings: AppSettings, inbound: Inbound? = nil,
                      allNodes: [ProxyNode] = []) throws -> String {
        let inbound = inbound ?? .localProxy(settings)
        var proxyOutbound = outbound(node, tag: proxyTag)
        var routeSection = route(settings)
        var inbounds = [inboundJSON(inbound, settings)]

        // Build outbounds: single proxy + direct, or urltest group when auto-switching is on.
        // IMPORTANT: a "proxy" tagged outbound must always exist because sing-box resolves
        // download_detour, DNS detour and route rules by tag at startup. In urltest mode we
        // emit a thin selector outbound tagged "proxy" that forwards through the "auto" group
        // so every tag reference resolves without changing the actual traffic path.
        var outbounds: [[String: Any]]
        let useUrlTest = settings.autoNodeSwitching && allNodes.count >= 2
        if useUrlTest {
            // One outbound per node (tagged node-<index>) plus the urltest group.
            var nodeOutbounds: [[String: Any]] = []
            var nodeTags: [String] = []
            for (i, n) in allNodes.enumerated() {
                let tag = "node-\(i)"
                nodeTags.append(tag)
                nodeOutbounds.append(outbound(n, tag: tag))
            }
            let intervalStr = "\(settings.urlTestInterval)s"
            let testURL = settings.urlTestURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let urlTestGroup: [String: Any] = [
                "type": "urltest",
                "tag": urlTestGroupTag,
                "outbounds": nodeTags,
                "url": testURL.isEmpty ? "https://www.gstatic.com/generate_204" : testURL,
                "interval": intervalStr,
                "tolerance": 50,
            ]
            // Selector tagged "proxy" wraps the urltest group so download_detour / DNS detour
            // references to "proxy" resolve correctly in both single-node and urltest modes.
            let proxySelector: [String: Any] = [
                "type": "selector",
                "tag": proxyTag,
                "outbounds": [urlTestGroupTag],
                "default": urlTestGroupTag,
            ]
            outbounds = nodeOutbounds + [urlTestGroup, proxySelector, ["type": "direct", "tag": directTag]]
            // Route final still points at the urltest group for direct latency-based selection.
            routeSection["final"] = urlTestGroupTag
        } else {
            outbounds = [proxyOutbound, ["type": "direct", "tag": directTag]]
        }

        if case .loopback = inbound {
            // User-space engine: the app has no TUN and iOS does not let it bind sockets to
            // interfaces, so the core must not select interfaces itself. Plain sockets follow the
            // system default route. With auto_detect_interface on, sing-box 1.11 refuses every dial
            // until a default interface is known: "open outbound connection: no available network
            // interface".
            if useUrlTest {
                // Merge dial fields into every node outbound (they are the first allNodes.count entries).
                for i in 0..<allNodes.count {
                    outbounds[i].merge(userSpaceDialFields()) { _, new in new }
                }
            } else {
                proxyOutbound.merge(userSpaceDialFields()) { _, new in new }
                outbounds[0] = proxyOutbound
            }
            routeSection["auto_detect_interface"] = false
            if let share = shareInbound(settings) { inbounds.append(share) }
        }

        let config: [String: Any] = [
            "log": ["level": settings.logLevel, "timestamp": true],
            "dns": dns(settings),
            "inbounds": inbounds,
            "outbounds": outbounds,
            "route": routeSection,
            "experimental": [
                "clash_api": ["external_controller": AppGroup.clashAPIAddress],
                "cache_file": ["enabled": true, "path": "cache.db"],
            ],
        ]
        let finalConfig = OTAOverrides.apply(to: config)
        let data = try JSONSerialization.data(
            withJSONObject: finalConfig,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Sections

    private static func inboundJSON(_ inbound: Inbound, _ s: AppSettings) -> [String: Any] {
        switch inbound {
        case .tun:
            return tunInbound(s)
        case .loopback(let host, let port):
            return mixedInbound(host: host, port: port)
        }
    }

    /// HTTP and SOCKS5 on one port. The primary listener's `listen` is loopback, so nothing on the
    /// LAN can reach it; the Proxy Share copy binds the selected interface address (or 0.0.0.0 for
    /// HOTSPOT while bridge100 is down). The MTU / stack / strict-route settings only apply to the
    /// TUN and are ignored here.
    private static func mixedInbound(host: String, port: Int) -> [String: Any] {
        [
            "type": "mixed",
            "tag": "mixed-in",
            "listen": host,
            "listen_port": port,
        ]
    }

    private static func tunInbound(_ s: AppSettings) -> [String: Any] {
        var addresses = ["172.19.0.1/30"]
        if s.ipv6Enabled { addresses.append("fdfe:dcba:9876::1/126") }
        return [
            "type": "tun",
            "tag": "tun-in",
            "address": addresses,
            "mtu": s.mtu,
            "auto_route": true,
            "strict_route": s.strictRoute,
            "stack": s.stack.rawValue,
        ]
    }

    private static func dns(_ s: AppSettings) -> [String: Any] {
        // Bundled core is sing-box v1.11.x (scripts/build-libbox.sh), so this uses the legacy
        // `address` schema. Inputs are trimmed and normalised first (see `legacyDNSAddress`).
        let remoteAddress = legacyDNSAddress(s.remoteDNS, fallback: "https://1.1.1.1/dns-query")
        let localAddress = legacyDNSAddress(s.localDNS, fallback: "local")

        var servers: [[String: Any]] = []
        var remote: [String: Any] = ["tag": "remote", "address": remoteAddress, "detour": proxyTag]
        var local: [String: Any] = ["tag": "local", "address": localAddress]
        // The system resolver does not dial through an outbound, so `local` gets no detour.
        if localAddress != "local" { local["detour"] = directTag }

        if !addressNeedsNoResolver(remoteAddress) { remote["address_resolver"] = "local" }
        if !addressNeedsNoResolver(localAddress) {
            servers.append(["tag": "bootstrap", "address": "udp://1.1.1.1", "detour": directTag])
            local["address_resolver"] = "bootstrap"
        }
        servers.append(remote)
        servers.append(local)

        var rules: [[String: Any]] = [["outbound": "any", "server": "local"]]
        if s.blockAds {
            servers.append(["tag": "block", "address": "rcode://success"])
            rules.append(["rule_set": ["geosite-category-ads-all"], "server": "block"])
        }
        if s.routingMode == .rule && s.bypassChina {
            rules.append(["rule_set": ["geosite-cn"], "server": "local"])
        }

        return [
            "servers": servers,
            "rules": rules,
            "final": s.routingMode == .direct ? "local" : "remote",
            "strategy": s.ipv6Enabled ? "prefer_ipv4" : "ipv4_only",
            "independent_cache": true,
        ]
    }

    private static func route(_ s: AppSettings) -> [String: Any] {
        var rules: [[String: Any]] = []
        var ruleSets: [[String: Any]] = []

        if s.sniffing { rules.append(["action": "sniff"]) }
        rules.append(["protocol": "dns", "action": "hijack-dns"])
        if s.routingMode != .direct {
            rules.append(["action": "resolve", "server": "remote", "strategy": "prefer_ipv4"])
        }
        if s.bypassLAN { rules.append(["ip_is_private": true, "outbound": directTag]) }

        if s.blockAds {
            ruleSets.append(remoteRuleSet("geosite-category-ads-all", url: geositeBase + "geosite-category-ads-all.srs"))
            rules.append(["rule_set": ["geosite-category-ads-all"], "action": "reject"])
        }

        for rule in s.customRules {
            if let json = customRule(rule) { rules.append(json) }
        }

        // User-supplied remote rule sets (Rules tab > Remote Rule Sets).
        for rrs in s.remoteRuleSets where rrs.enabled {
            let tag = rrs.tag.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = rrs.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty, !url.isEmpty else { continue }
            ruleSets.append(remoteRuleSet(tag, url: url))
            rules.append(["rule_set": [tag], "outbound": proxyTag])
        }

        let finalOutbound: String
        switch s.routingMode {
        case .rule:
            if s.bypassChina {
                ruleSets.append(remoteRuleSet("geosite-cn", url: geositeBase + "geosite-cn.srs"))
                ruleSets.append(remoteRuleSet("geoip-cn", url: geoipBase + "geoip-cn.srs"))
                rules.append(["rule_set": ["geosite-cn", "geoip-cn"], "outbound": directTag])
            }
            finalOutbound = proxyTag
        case .global:
            finalOutbound = proxyTag
        case .direct:
            finalOutbound = directTag
        }

        return [
            "rules": rules,
            "rule_set": ruleSets,
            "final": finalOutbound,
            "auto_detect_interface": true,
        ]
    }

    private static func remoteRuleSet(_ tag: String, url: String) -> [String: Any] {
        [
            "type": "remote",
            "tag": tag,
            "format": "binary",
            "url": url,
            "download_detour": proxyTag,
            "update_interval": "24h",
        ]
    }

    private static func customRule(_ rule: CustomRule) -> [String: Any]? {
        let values = rule.value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !values.isEmpty else { return nil }

        var json: [String: Any] = [:]
        switch rule.kind {
        case .domainSuffix: json["domain_suffix"] = values
        case .domainKeyword: json["domain_keyword"] = values
        case .domain: json["domain"] = values
        case .ipCIDR: json["ip_cidr"] = values
        }
        switch rule.action {
        case .proxy: json["outbound"] = proxyTag
        case .direct: json["outbound"] = directTag
        case .block: json["action"] = "reject"
        }
        return json
    }

    // MARK: - Outbound

    /// Dial options merged into the `proxy` outbound of the user-space build. sing-box flattens
    /// dial fields into the outbound object (next to `server` / `server_port`); there is no nested
    /// `dial_fields` key and unknown keys are rejected. `bind_interface`, `routing_mark`,
    /// `inet4_bind_address` and `inet6_bind_address` are deliberately absent: iOS does not let an
    /// app pin sockets to an interface or set fwmarks, and a plain socket already follows the
    /// system default route.
    private static func userSpaceDialFields() -> [String: Any] {
        ["domain_strategy": "prefer_ipv4"]
    }

    static func outbound(_ n: ProxyNode, tag: String) -> [String: Any] {
        var o: [String: Any] = ["tag": tag, "server": n.server, "server_port": n.port]

        switch n.kind {
        case .shadowsocks:
            o["type"] = "shadowsocks"
            o["method"] = n.method ?? "aes-256-gcm"
            o["password"] = n.password ?? ""
            if let plugin = n.plugin?.nonEmpty {
                o["plugin"] = plugin
                if let opts = n.pluginOpts?.nonEmpty { o["plugin_opts"] = opts }
            }

        case .vmess:
            o["type"] = "vmess"
            o["uuid"] = n.uuid ?? ""
            o["security"] = n.security ?? "auto"
            o["alter_id"] = n.alterId ?? 0
            if let tls = tls(n, force: false) { o["tls"] = tls }
            if let transport = transport(n) { o["transport"] = transport }

        case .vless:
            o["type"] = "vless"
            o["uuid"] = n.uuid ?? ""
            if let flow = n.flow?.nonEmpty { o["flow"] = flow }
            o["packet_encoding"] = "xudp"
            if let tls = tls(n, force: false) { o["tls"] = tls }
            if let transport = transport(n) { o["transport"] = transport }

        case .trojan:
            o["type"] = "trojan"
            o["password"] = n.password ?? ""
            if let tls = tls(n, force: true) { o["tls"] = tls }
            if let transport = transport(n) { o["transport"] = transport }

        case .socks:
            o["type"] = "socks"
            o["version"] = "5"
            if let user = n.username?.nonEmpty { o["username"] = user }
            if let pass = n.password?.nonEmpty { o["password"] = pass }

        case .http:
            o["type"] = "http"
            if let user = n.username?.nonEmpty { o["username"] = user }
            if let pass = n.password?.nonEmpty { o["password"] = pass }
            if let tls = tls(n, force: false) { o["tls"] = tls }

        case .hysteria2:
            o["type"] = "hysteria2"
            o["password"] = n.password ?? ""
            if let obfs = n.obfs?.nonEmpty {
                o["obfs"] = ["type": obfs, "password": n.obfsPassword ?? ""]
            }
            if let up = n.upMbps { o["up_mbps"] = up }
            if let down = n.downMbps { o["down_mbps"] = down }
            if let tls = tls(n, force: true, defaultALPN: ["h3"]) { o["tls"] = tls }

        case .hysteria:
            o["type"] = "hysteria"
            o["auth_str"] = n.password ?? ""
            o["up_mbps"] = n.upMbps ?? 100
            o["down_mbps"] = n.downMbps ?? 100
            if let obfs = n.obfs?.nonEmpty { o["obfs"] = obfs }
            if let tls = tls(n, force: true, defaultALPN: ["h3"]) { o["tls"] = tls }

        case .tuic:
            o["type"] = "tuic"
            o["uuid"] = n.uuid ?? ""
            o["password"] = n.password ?? ""
            o["congestion_control"] = n.congestionControl ?? "cubic"
            o["udp_relay_mode"] = n.udpRelayMode ?? "native"
            if let tls = tls(n, force: true, defaultALPN: ["h3"]) { o["tls"] = tls }

        case .wireguard:
            o["type"] = "wireguard"
            o["local_address"] = n.localAddress.isEmpty ? ["10.0.0.2/32"] : n.localAddress
            o["private_key"] = n.privateKey ?? ""
            o["peer_public_key"] = n.peerPublicKey ?? ""
            if let psk = n.preSharedKey?.nonEmpty { o["pre_shared_key"] = psk }
            o["mtu"] = n.mtu ?? 1408
            if !n.reserved.isEmpty { o["reserved"] = n.reserved }
        }
        return o
    }

    private static func tls(_ n: ProxyNode, force: Bool, defaultALPN: [String] = []) -> [String: Any]? {
        guard n.tls || force else { return nil }
        var t: [String: Any] = ["enabled": true, "insecure": n.insecure]
        if let sni = n.sni?.nonEmpty ?? n.host?.nonEmpty {
            t["server_name"] = sni
        }
        let alpn = n.alpn.isEmpty ? defaultALPN : n.alpn
        if !alpn.isEmpty { t["alpn"] = alpn }
        if let fingerprint = n.fingerprint?.nonEmpty {
            t["utls"] = ["enabled": true, "fingerprint": fingerprint]
        }
        if let publicKey = n.realityPublicKey?.nonEmpty {
            t["reality"] = ["enabled": true, "public_key": publicKey, "short_id": n.realityShortID ?? ""]
            if t["utls"] == nil {
                t["utls"] = ["enabled": true, "fingerprint": "chrome"]
            }
        }
        return t
    }

    private static func transport(_ n: ProxyNode) -> [String: Any]? {
        switch n.transport {
        case .tcp:
            return nil
        case .ws:
            var path = n.path ?? "/"
            var t: [String: Any] = ["type": "ws"]
            if let range = path.range(of: "?ed=") {
                if let maxEarlyData = Int(path[range.upperBound...]) {
                    t["max_early_data"] = maxEarlyData
                    t["early_data_header_name"] = "Sec-WebSocket-Protocol"
                }
                path = String(path[..<range.lowerBound])
            }
            t["path"] = path
            if let host = n.host?.nonEmpty { t["headers"] = ["Host": host] }
            return t
        case .grpc:
            return ["type": "grpc", "service_name": n.serviceName ?? ""]
        case .http:
            var t: [String: Any] = ["type": "http"]
            if let host = n.host?.nonEmpty { t["host"] = [host] }
            if let path = n.path?.nonEmpty { t["path"] = path }
            return t
        case .httpupgrade:
            return ["type": "httpupgrade", "host": n.host ?? "", "path": n.path ?? "/"]
        case .quic:
            return ["type": "quic"]
        }
    }

    // MARK: - Helpers

    /// Normalises a DNS address typed in Settings for the sing-box 1.11 legacy `address` schema:
    /// trims whitespace, maps "System" / "local" to `local`, passes any URL with a scheme
    /// (`https://`, `tls://`, `udp://`, ...) through unchanged, and prepends `udp://` to a plain
    /// IP or host (IPv6 literals are bracketed). Empty input falls back to `fallback`.
    static func legacyDNSAddress(_ raw: String, fallback: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return fallback }
        let lowered = value.lowercased()
        if lowered == "local" || lowered == "system" { return "local" }
        if value.contains("://") { return value }
        if IPv6Address(value) != nil { return "udp://[\(value)]" }
        return "udp://" + value
    }

    /// True when the DNS address can be used without another server resolving its host name.
    private static func addressNeedsNoResolver(_ address: String) -> Bool {
        let lowered = address.lowercased()
        if lowered == "local" || lowered.hasPrefix("dhcp://") || lowered.hasPrefix("rcode://") { return true }
        var host = address
        if let range = host.range(of: "://") { host = String(host[range.upperBound...]) }
        if let slash = host.firstIndex(of: "/") { host = String(host[..<slash]) }
        host = RawProxyURL.hostPort(host).host
        return IPv4Address(host) != nil || IPv6Address(host) != nil
    }
}
