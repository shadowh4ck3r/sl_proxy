import Foundation
import Network

/// Turns the selected node and user settings into a sing-box 1.11 JSON configuration.
enum SingBoxConfigBuilder {
    static let proxyTag = "proxy"
    static let directTag = "direct"
    /// Tag of the urltest outbound group used when Auto Node Switching is on.
    static let urlTestGroupTag = "auto"
    /// Tag of the extra outbound that carries Remote DNS when "Tunnel DNS through proxy" is on.
    static let dnsProxyTag = "dns-proxy"
    /// UserDefaults key of the DNS Settings switch (read here, written by `@AppStorage`).
    static let tunnelDNSKey = "tunnelDNSThroughProxy"

    static var tunnelDNSEnabled: Bool { UserDefaults.standard.bool(forKey: tunnelDNSKey) }

    /// Call right before `build` when the switch is on: looks the proxy host name up with a plain
    /// UDP query (Local DNS, or 1.1.1.1) and caches the IP, so the DNS-only outbound can dial an
    /// address and never has to resolve a name in the middle of a Remote DNS request. Blocks for
    /// at most about 1.5 s; on failure the old cached IP (if any) is kept.
    static func prepareDNSTunnel(node: ProxyNode, settings: AppSettings) {
        guard tunnelDNSEnabled, settings.routingMode != .direct else { return }
        let host = node.server.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty, IPv4Address(host) == nil, IPv6Address(host) == nil else { return }
        ProxyHostResolver.warm(host: host, dnsServer: bootstrapDNSServer(settings))
    }

    /// IPv4 address of the resolver used for that lookup: the user's Local DNS when it is a plain
    /// IPv4 address, otherwise 1.1.1.1. Never the iOS system resolver (see `dns`).
    private static func bootstrapDNSServer(_ s: AppSettings) -> String {
        var value = legacyDNSAddress(s.localDNS, fallback: "local")
        if value.hasPrefix("udp://") { value = String(value.dropFirst(6)) }
        if IPv4Address(value) != nil { return value }
        return "1.1.1.1"
    }

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

        // Optional: carry Remote DNS through a copy of the selected node that dials the proxy by IP.
        var remoteDetour = directTag
        if tunnelDNSEnabled, settings.routingMode != .direct, let dnsOutbound = dnsProxyOutbound(node) {
            outbounds.append(dnsOutbound)
            remoteDetour = dnsProxyTag
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
            "dns": dns(settings, serverHosts: (allNodes + [node]).map { $0.server }, remoteDetour: remoteDetour),
            "inbounds": inbounds,
            "outbounds": outbounds,
            "route": routeSection,
            "experimental": [
                "clash_api": ["external_controller": AppGroup.clashAPIAddress],
                "cache_file": ["enabled": true, "path": "cache.db"],
            ],
        ]
        // OTA hook: `singbox_overrides` from ui.json flags is deep-merged here, right before the
        // config is serialised and written (listeners and the Clash API are protected).
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

    private static func dns(_ s: AppSettings, serverHosts: [String] = [], remoteDetour: String = directTag) -> [String: Any] {
        // Bundled core is sing-box v1.11.x (scripts/build-libbox.sh), so this uses the legacy
        // `address` schema. Inputs are trimmed and normalised first (see `legacyDNSAddress`).
        let remoteAddress = legacyDNSAddress(s.remoteDNS, fallback: "https://1.1.1.1/dns-query")
        let localAddress = legacyDNSAddress(s.localDNS, fallback: "local")

        var servers: [[String: Any]] = []
        // `remote` is dialled over the DIRECT outbound, not through `proxy`. The route's `resolve`
        // action makes sing-box ask `remote` for a domain while that connection is being routed.
        // If the DoH / DoT request itself had to go through the `proxy` outbound, dialling that
        // outbound would trigger a nested lookup of the proxy's own host name inside the same
        // `remote` exchange, and sing-box aborts it with "DNS query loopback in transport[remote]"
        // (every Rule / Global connection then dies). The encrypted query still goes to the
        // resolver the user chose, so sites like ip8.com report that resolver instead of the
        // SOCKS5 server's upstream DNS; only the hop to the resolver is no longer tunnelled.
        var remote: [String: Any] = ["tag": "remote", "address": remoteAddress, "detour": remoteDetour]
        var local: [String: Any] = ["tag": "local", "address": localAddress]
        // The system resolver does not dial through an outbound, so `local` gets no detour.
        if localAddress != "local" { local["detour"] = directTag }

        // Names sing-box must resolve BEFORE it can dial anything (the upstream proxy host name,
        // a DoH / DoT host name) need a resolver that never depends on the proxy being up.
        //
        // The iOS system resolver is fine for that, UNLESS "System Encrypted DNS" is on: the system
        // DoH profile then sends every lookup to the DoH server over TCP 443, and with the cellular
        // profile that connection is carried into our own mixed-in listener and out through the
        // proxy outbound, which cannot dial until ITS host name resolves. Deadlock: the dial waits
        // for the system resolver, the system resolver waits for the dial, and the lookup ends in
        // "lookup <proxy host>: i/o timeout". Direct mode never dials the proxy outbound, which is
        // why only Rule / Global broke. So while that toggle is on, resolve those names with plain
        // UDP over the direct outbound instead (the user's Local DNS, or 1.1.1.1 when Local DNS is
        // "System").
        let systemDNSInUse = UserDefaults.standard.bool(forKey: "systemEncryptedDNS")
        let dialResolver: String
        if !systemDNSInUse {
            dialResolver = "system"
        } else if localAddress == "local" {
            dialResolver = "bootstrap"
        } else {
            dialResolver = "local"
        }

        if !addressNeedsNoResolver(remoteAddress) {
            remote["address_resolver"] = dialResolver == "system" ? "local" : dialResolver
        }
        if !addressNeedsNoResolver(localAddress) || dialResolver == "bootstrap" {
            servers.append(["tag": "bootstrap", "address": "udp://1.1.1.1", "detour": directTag])
        }
        if !addressNeedsNoResolver(localAddress) { local["address_resolver"] = "bootstrap" }
        servers.append(remote)
        servers.append(local)

        if dialResolver == "system" {
            servers.append(["tag": "system", "address": "local"])
        }
        let hosts = Array(Set(serverHosts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && IPv4Address($0) == nil && IPv6Address($0) == nil })).sorted()
        var rules: [[String: Any]] = []
        if !hosts.isEmpty { rules.append(["domain": hosts, "server": dialResolver]) }
        rules.append(["outbound": "any", "server": dialResolver])
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
        // Resolve destination domains here, with the user's Remote DNS, BEFORE they are forwarded
        // to the upstream SOCKS5 / HTTP server. Without it the domain name is handed to the
        // upstream server and ITS resolver answers (ip8.com then shows the server's DNS).
        // Direct mode keeps the local resolver and skips this.
        if s.routingMode != .direct {
            rules.append(["action": "resolve", "server": "remote",
                          "strategy": s.ipv6Enabled ? "prefer_ipv4" : "ipv4_only"])
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

    /// Copy of `node` tagged `dns-proxy` that dials the proxy by IP address. Nil (so Remote DNS
    /// stays on the direct outbound) when the host name has no cached IP or the node is WireGuard.
    private static func dnsProxyOutbound(_ node: ProxyNode) -> [String: Any]? {
        if node.kind == .wireguard { return nil }
        var o = outbound(node, tag: dnsProxyTag)
        let host = node.server.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if IPv4Address(host) != nil || IPv6Address(host) != nil { return o }
        guard let ip = ProxyHostResolver.cached(host) else { return nil }
        o["server"] = ip
        // The host name is still what TLS (SNI) and WebSocket / HTTPUpgrade Host should say.
        if var tls = o["tls"] as? [String: Any], tls["server_name"] == nil {
            tls["server_name"] = node.server
            o["tls"] = tls
        }
        if var transport = o["transport"] as? [String: Any], let type = transport["type"] as? String {
            if type == "ws" {
                var headers = transport["headers"] as? [String: Any] ?? [:]
                if headers["Host"] == nil { headers["Host"] = node.server }
                transport["headers"] = headers
            } else if type == "httpupgrade", (transport["host"] as? String ?? "").isEmpty {
                transport["host"] = node.server
            }
            o["transport"] = transport
        }
        return o
    }

    // MARK: - Outbound

    /// Dial options merged into the `proxy` outbound of the user-space build. sing-box flattens
    /// dial fields into the outbound object (next to `server` / `server_port`); there is no nested
    /// `dial_fields` key and unknown keys are rejected. `bind_interface`, `routing_mark`,
    /// `inet4_bind_address` and `inet6_bind_address` are deliberately absent: iOS does not let an
    /// app pin sockets to an interface or set fwmarks, and a plain socket already follows the
    /// system default route.
    private static func userSpaceDialFields() -> [String: Any] {
        [:]
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

/// Resolves a proxy host name to IPv4 with one plain UDP DNS query on a POSIX socket. It never
/// uses the iOS system resolver, so it cannot be caught in the System Encrypted DNS deadlock.
enum ProxyHostResolver {
    private static let lock = NSLock()
    private static var cache: [String: String] = [:]

    static func cached(_ host: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return cache[host.lowercased()]
    }

    /// Queries `dnsServer` (IPv4 literal) for `host` and caches the answer. Returns the IP, or
    /// the previously cached one when the query fails.
    @discardableResult
    static func warm(host: String, dnsServer: String) -> String? {
        let key = host.lowercased()
        guard let ip = queryA(host: key, server: dnsServer, timeout: 1.5) else { return cached(key) }
        lock.lock()
        cache[key] = ip
        lock.unlock()
        return ip
    }

    private static func queryA(host: String, server: String, timeout: Double) -> String? {
        let id = UInt16.random(in: 1...UInt16.max)
        var query: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0x01, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
        for label in host.split(separator: ".") {
            let bytes = Array(label.utf8)
            guard !bytes.isEmpty, bytes.count < 64 else { return nil }
            query.append(UInt8(bytes.count))
            query.append(contentsOf: bytes)
        }
        query.append(contentsOf: [0x00, 0x00, 0x01, 0x00, 0x01])

        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(53).bigEndian
        guard inet_pton(AF_INET, server, &addr.sin_addr) == 1 else { return nil }

        let sent = withUnsafePointer(to: &addr) { pointer -> Int in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                sendto(fd, query, query.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard sent == query.count else { return nil }

        let capacity = 1500
        var buffer = [UInt8](repeating: 0, count: capacity)
        let received = recv(fd, &buffer, capacity, 0)
        guard received >= 12 else { return nil }
        return parseA(Array(buffer[0..<received]), id: id)
    }

    private static func skipName(_ b: [UInt8], _ start: Int) -> Int? {
        var i = start
        while i < b.count {
            let length = Int(b[i])
            if length == 0 { return i + 1 }
            if length & 0xC0 == 0xC0 { return i + 2 <= b.count ? i + 2 : nil }
            i += 1 + length
        }
        return nil
    }

    private static func parseA(_ b: [UInt8], id: UInt16) -> String? {
        guard b.count >= 12, b[0] == UInt8(id >> 8), b[1] == UInt8(id & 0xFF) else { return nil }
        guard b[3] & 0x0F == 0 else { return nil }
        let questions = Int(b[4]) << 8 | Int(b[5])
        let answers = Int(b[6]) << 8 | Int(b[7])
        var i = 12
        for _ in 0..<questions {
            guard let next = skipName(b, i) else { return nil }
            i = next + 4
        }
        for _ in 0..<answers {
            guard let n = skipName(b, i), n + 10 <= b.count else { return nil }
            let type = Int(b[n]) << 8 | Int(b[n + 1])
            let length = Int(b[n + 8]) << 8 | Int(b[n + 9])
            let data = n + 10
            guard data + length <= b.count else { return nil }
            if type == 1, length == 4 {
                return "\(b[data]).\(b[data + 1]).\(b[data + 2]).\(b[data + 3])"
            }
            i = data + length
        }
        return nil
    }
}
