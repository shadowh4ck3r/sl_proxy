import Combine
import Foundation
import SwiftUI

enum RoutingMode: String, Codable, CaseIterable, Identifiable {
    case rule, global, direct

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rule: return "Rule"
        case .global: return "Global"
        case .direct: return "Direct"
        }
    }

    var detail: String {
        switch self {
        case .rule: return "Bypass LAN and selected traffic, proxy everything else"
        case .global: return "Send all traffic through the proxy"
        case .direct: return "Keep the tunnel up but send traffic directly"
        }
    }
}

enum TunStack: String, Codable, CaseIterable, Identifiable {
    case mixed, system, gvisor
    var id: String { rawValue }
}

enum RuleKind: String, Codable, CaseIterable, Identifiable {
    case domainSuffix, domainKeyword, domain, ipCIDR

    var id: String { rawValue }

    var title: String {
        switch self {
        case .domainSuffix: return "Domain suffix"
        case .domainKeyword: return "Domain keyword"
        case .domain: return "Exact domain"
        case .ipCIDR: return "IP / CIDR"
        }
    }

    var placeholder: String {
        switch self {
        case .domainSuffix: return "example.com"
        case .domainKeyword: return "google"
        case .domain: return "www.example.com"
        case .ipCIDR: return "10.0.0.0/8"
        }
    }
}

enum RuleAction: String, Codable, CaseIterable, Identifiable {
    case proxy, direct, block

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct CustomRule: Codable, Identifiable, Hashable {
    var id = UUID()
    var kind: RuleKind
    var value: String
    var action: RuleAction
}

struct DNSPreset: Identifiable {
    let name: String
    let address: String
    var id: String { address }

    static let remote: [DNSPreset] = [
        DNSPreset(name: "Cloudflare (DoH)", address: "https://1.1.1.1/dns-query"),
        DNSPreset(name: "Google (DoH)", address: "https://8.8.8.8/dns-query"),
        DNSPreset(name: "Quad9 (DoH)", address: "https://9.9.9.9/dns-query"),
        DNSPreset(name: "AdGuard (DoH)", address: "https://94.140.14.14/dns-query"),
        DNSPreset(name: "Cloudflare (UDP)", address: "1.1.1.1"),
    ]

    static let local: [DNSPreset] = [
        DNSPreset(name: "Cloudflare", address: "1.1.1.1"),
        DNSPreset(name: "Google", address: "8.8.8.8"),
        DNSPreset(name: "AliDNS", address: "223.5.5.5"),
        DNSPreset(name: "DNSPod", address: "119.29.29.29"),
        DNSPreset(name: "System", address: "local"),
    ]
}

/// Physical interface the Proxy Share listener binds to (the CELLULAR / WIFI / HOTSPOT picker).
enum ShareInterface: String, Codable, CaseIterable, Identifiable {
    case cellular = "CELLULAR"
    case wifi = "WIFI"
    /// Personal Hotspot: the `bridge100` NAT bridge iOS creates for tethered clients, gateway
    /// `hotspotGatewayAddress`. iOS only brings bridge100 up once a client is tethered, so the
    /// config builder falls back to `wildcardAddress` while it is down
    /// (see `SingBoxConfigBuilder.shareListenAddress`).
    case hotspot = "HOTSPOT"

    var id: String { rawValue }
    var title: String { rawValue }

    /// Gateway address iOS assigns to `bridge100` whenever Personal Hotspot is active.
    static let hotspotGatewayAddress = "172.20.10.1"
    /// Every IPv4 interface. Used for HOTSPOT while bridge100 has no address yet, so hotspot
    /// clients reach the listener at `hotspotGatewayAddress` as soon as the bridge comes up.
    static let wildcardAddress = "0.0.0.0"

    /// BSD interface names tried in order when resolving the listen address.
    var bsdNames: [String] {
        switch self {
        case .wifi: return ["en0"]
        case .cellular: return ["pdp_ip0", "pdp_ip1", "pdp_ip2", "pdp_ip3"]
        case .hotspot: return ["bridge100"]
        }
    }
}

/// App-wide colour scheme override (Appearance Settings > Theme).
enum AppColorScheme: String, Codable, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System Default"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var systemImage: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    /// The SwiftUI `ColorScheme` to pass to `.preferredColorScheme()`, or nil for system default.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// App-wide font style (Appearance Settings > App Font). Resolved into a SwiftUI `Font.Design`
/// and applied through the `.appFont()` modifier so every screen follows the chosen typography.
enum AppFontStyle: String, Codable, CaseIterable, Identifiable {
    /// System default (SF Pro).
    case system
    /// Fixed-width, keeps `host:port` strings aligned.
    case mono
    /// The custom handwritten / chalk style seen on the Home screen (rounded SF).
    case sketch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .mono: return "Mono"
        case .sketch: return "Sketch"
        }
    }

    var detail: String {
        switch self {
        case .system: return "SF Pro, the iOS default typeface."
        case .mono: return "Fixed-width digits and letters; keeps host:port strings aligned."
        case .sketch: return "The custom handwritten / chalk style from the Home screen."
        }
    }

    /// SwiftUI font design the `.appFont()` modifier applies to the whole app.
    var design: Font.Design {
        switch self {
        case .system: return .default
        case .mono: return .monospaced
        case .sketch: return .rounded
        }
    }
}

/// Home layout chosen in Appearance Settings > Navigation Style.
enum NavigationStyle: String, Codable, CaseIterable, Identifiable {
    case erosion, katzy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .erosion: return "Erosion"
        case .katzy: return "Katzy"
        }
    }

    var detail: String {
        switch self {
        case .erosion: return "Flat surfaces with solid edges and the brand gradient as accent."
        case .katzy: return "Katzy glassmorphism: frosted, translucent cards with a gold-to-orange edge glow."
        }
    }

    /// Layout flag for the Katzy glassmorphism design. Views consult this (via
    /// `navigationStyleCard`) instead of comparing cases so new styles slot in later.
    var usesGlassmorphism: Bool { self == .katzy }
}

/// Diameter of the Connect button on Home (Appearance Settings > Connection Button Size).
/// `HomeView` reads these through `SettingsStore`, so a change in Appearance Settings resizes the
/// ring immediately.
enum ConnectionButtonSize: String, Codable, CaseIterable, Identifiable {
    case small, medium, large

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// Diameter of the Connect button, in points. The same size is used on Home (in the card or
    /// docked) and on the other tabs. Small matches the compact floating button of V2Box (about
    /// 60 pt); the old 128 / 172 / 216 pt rings were far too large for a floating button.
    var diameter: CGFloat {
        switch self {
        case .small: return 60
        case .medium: return 84
        case .large: return 112
        }
    }

    /// Stroke width of the gradient ring.
    var ringLineWidth: CGFloat {
        switch self {
        case .small: return 3
        case .medium: return 4
        case .large: return 5
        }
    }
}

/// User-Agent sent when a subscription is refreshed (Subscription Settings > User-Agent).
enum UserAgentPreset: String, Codable, CaseIterable, Identifiable {
    case appDefault, chromeDesktop, chromeAndroid, safariDesktop, safariMobile, firefoxDesktop, edgeDesktop, v2rayNG, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appDefault: return "SL_Proxy (default)"
        case .chromeDesktop: return "Chrome Desktop"
        case .chromeAndroid: return "Chrome Android"
        case .safariDesktop: return "Safari Desktop"
        case .safariMobile: return "Safari Mobile"
        case .firefoxDesktop: return "Firefox Desktop"
        case .edgeDesktop: return "Edge Desktop"
        case .v2rayNG: return "v2rayNG"
        case .custom: return "Custom Entry"
        }
    }

    /// Header value for the preset; nil for the app default and for `custom`, which are resolved
    /// by `AppSettings.effectiveSubscriptionUserAgent`.
    var value: String? {
        switch self {
        case .appDefault, .custom:
            return nil
        case .chromeDesktop:
            return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"
        case .chromeAndroid:
            return "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Mobile Safari/537.36"
        case .safariDesktop:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"
        case .safariMobile:
            return "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1"
        case .firefoxDesktop:
            return "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:130.0) Gecko/20100101 Firefox/130.0"
        case .edgeDesktop:
            return "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36 Edg/128.0.0.0"
        case .v2rayNG:
            return "v2rayNG/1.8.29"
        }
    }
}

/// Network an On-Demand rule matches against.
enum OnDemandInterfaceKind: String, Codable, CaseIterable, Identifiable {
    case wifiSSID, cellularNetwork

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wifiSSID: return "Wi-Fi SSID"
        case .cellularNetwork: return "Cellular Network"
        }
    }

    /// Noun used in rule summaries ("when on Wi-Fi network X").
    var subject: String {
        switch self {
        case .wifiSSID: return "Wi-Fi network"
        case .cellularNetwork: return "cellular network"
        }
    }

    var placeholder: String {
        switch self {
        case .wifiSSID: return "Home_WiFi"
        case .cellularNetwork: return "Carrier name"
        }
    }

    var systemImage: String {
        switch self {
        case .wifiSSID: return "wifi"
        case .cellularNetwork: return "antenna.radiowaves.left.and.right"
        }
    }
}

/// What the On-Demand engine does when a rule matches.
enum OnDemandAction: String, Codable, CaseIterable, Identifiable {
    case connect, disconnect, ignore

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var detail: String {
        switch self {
        case .connect: return "start the proxy"
        case .disconnect: return "stop the proxy"
        case .ignore: return "leave the proxy as it is"
        }
    }
}

/// One row of the On-Demand rule builder: "on <interface> named <networkName>, <action>".
struct OnDemandRule: Codable, Identifiable, Hashable {
    var id = UUID()
    var interface: OnDemandInterfaceKind = .wifiSSID
    var networkName = ""
    var action: OnDemandAction = .connect
}

/// A user-supplied remote rule-set entry (Rules tab > Remote Rule Sets).
/// Each enabled entry is emitted as a binary `remote` rule_set in the sing-box config and
/// matched with an `outbound: proxy` route rule.
struct RemoteRuleSet: Codable, Identifiable, Hashable {
    var id = UUID()
    /// Short tag used in the sing-box config; must be unique across all rule sets.
    var tag: String
    /// HTTPS URL of the compiled `.srs` binary rule-set file.
    var url: String
    /// When false the entry is stored but not emitted into the config.
    var enabled = true
}

/// User preferences that shape the generated sing-box configuration.
struct AppSettings: Codable, Equatable {
    var routingMode: RoutingMode = .rule
    var bypassLAN = true
    var bypassChina = false
    var blockAds = false
    var customRules: [CustomRule] = []

    var remoteDNS = "https://1.1.1.1/dns-query"
    var localDNS = "1.1.1.1"

    var mtu = 9000
    var stack: TunStack = .mixed
    var ipv6Enabled = false
    var strictRoute = false
    var sniffing = true

    var autoConnectOnLaunch = false
    var logLevel = "info"
    /// User-space build: keep the in-app proxy alive when the app is minimized (silent audio
    /// session + background task, see BackgroundKeepAlive).
    var keepAliveInBackground = true
    /// User-space build: while the loopback port is held, keep a delayed "SL_Proxy stopped"
    /// notification pending and push it back every few seconds. If iOS kills the app the push-backs
    /// stop and the notification fires, so the user knows cellular data is blocked (see
    /// EngineWatchdog).
    var engineWatchdog = true
    /// User-space build: port of the loopback HTTP + SOCKS5 (`mixed`) listener. 1080 is what every
    /// other proxy tool on the device grabs ("bind: address already in use"), so the default is
    /// 20080. Values outside `localProxyPortRange` fall back to the default.
    var localProxyPort = AppSettings.defaultLocalProxyPort
    /// When the chosen port is busy, try the preset alternatives in order, then the first free
    /// port above the chosen one, instead of failing.
    var localProxyPortFallback = true

    /// Proxy Share: expose a second HTTP + SOCKS5 listener on a physical interface so other devices
    /// on that network can use this proxy.
    var shareEnabled = false
    /// Interface whose IPv4 address the shared listener binds to. HOTSPOT binds the bridge100
    /// gateway (172.20.10.1) or 0.0.0.0 while the bridge is down.
    var shareInterface: ShareInterface = .wifi
    /// Port of the shared listener. When it is busy at start the engine scans upward (port + 1,
    /// port + 2, ...) and the port actually bound is shown in Proxy Share Settings.
    var sharePort = AppSettings.defaultSharePort
    /// Proxy Share: require a username and password on the shared listener. sing-box enforces
    /// them on both protocols (HTTP Basic and SOCKS5 username/password). Nothing is enforced while
    /// either field is blank (see `shareCredentials`); the loopback listener is never protected.
    var shareAuthEnabled = false
    var shareUsername = ""
    var sharePassword = ""
    /// Proxy Share: serve a proxy auto-config script (`/proxy.pac`) on the shared interface address
    /// so tethered devices configure themselves from one URL (see `PACServer`).
    var pacEnabled = false
    /// Port of the PAC server. A busy port is replaced by the first free one scanning upward.
    var pacPort = AppSettings.defaultPACPort

    // Appearance Settings. None of these reach the sing-box config, so changing them never
    // restarts the running core.
    var colorScheme: AppColorScheme = .system
    /// App-wide typography (Appearance Settings > App Font).
    var fontStyle: AppFontStyle = .system
    var navigationStyle: NavigationStyle = .erosion
    var connectionButtonSize: ConnectionButtonSize = .medium
    /// Keep the Connect button at a fixed spot instead of scrolling with the Home content.
    var fixedButtonPosition = false
    /// Show the Connect button on the Home tab only (off: on every tab).
    var showButtonOnlyInHomeTab = true
    /// Where the floating Connect button was dropped, as a fraction (0...1) of the screen width and
    /// height; nil = the default spot at the bottom-left.
    var connectButtonX: Double?
    var connectButtonY: Double?

    // Subscription Settings.
    /// Refresh subscriptions automatically on launch / in the background.
    var subscriptionAutoUpdate = true
    /// Show announcements published by subscription providers.
    var showAnnouncements = true
    /// Attach a per-install hardware identifier to subscription requests.
    var sendHWID = false
    /// Browser fingerprint presented to subscription servers; see `effectiveSubscriptionUserAgent`.
    var subscriptionUserAgentPreset: UserAgentPreset = .appDefault
    /// Used when `subscriptionUserAgentPreset` is `.custom`.
    var customSubscriptionUserAgent = ""

    // Advanced & Pro Settings: Combine WiFi + Cellular (Multipath TCP / sing-box hybrid routing).
    // Stored for the hybrid routing engine; not part of the generated config yet.
    var combineWiFiCellular = false
    /// Let the engine balance the two links; off exposes the two ratios below.
    var combineAutoRatio = true
    /// Share of traffic steered over Wi-Fi, 0...100 percent. Independent of `cellularRatio`.
    var wifiRatio = 50
    /// Share of traffic steered over cellular, 0...100 percent. Independent of `wifiRatio`.
    var cellularRatio = 50

    // On-Demand Settings.
    var onDemandEnabled = false
    /// Evaluated top to bottom; the first matching rule wins.
    var onDemandRules: [OnDemandRule] = []

    // Auto Node Switching (Advanced & Pro > Auto Node Switching).
    /// When true, SingBoxConfigBuilder wraps all nodes in a urltest outbound group.
    var autoNodeSwitching = false
    /// Seconds between automatic latency tests (30 – 3600).
    var urlTestInterval = 300
    /// URL the urltest group fetches to measure latency.
    var urlTestURL = "https://www.gstatic.com/generate_204"

    // Remote Rule Sets (Rules tab > Remote Rule Sets).
    var remoteRuleSets: [RemoteRuleSet] = []

    // Carrier Profile (Advanced & Pro > Carrier Profile).
    /// Carrier chosen by hand; nil uses the SIM detected through CoreTelephony.
    var carrierOverride: Carrier?
    /// Directory the per-carrier `.mobileconfig` files are downloaded from. Defaults to the latest
    /// `build_ipa` artifacts of this branch; `carrierProfileURL(for:)` appends the file name.
    var carrierProfileBaseURL = AppSettings.defaultCarrierProfileBaseURL

    // Data Budget (Advanced & Pro > Data Budget). Bytes are counted only while the device path is
    // cellular; see `DataBudgetTracker`.
    var dataBudgetEnabled = false
    /// Daily cap in megabytes (10^6 bytes); 0 disables the daily cap.
    var dailyCapMB = 500
    /// Monthly cap in megabytes; 0 disables the monthly cap.
    var monthlyCapMB = 10_000
    /// Post local notifications at 90% and 100% of a cap.
    var budgetNotifications = true
    /// Disconnect the engine when a cap is reached (and refuse to connect on cellular until reset).
    var budgetAutoDisconnect = true

    static let ratioRange = 0...100

    static let mtuOptions = [1280, 1400, 1500, 4064, 9000]
    static let logLevels = ["trace", "debug", "info", "warn", "error"]

    /// The mixed inbound only ever listens on loopback.
    static let localProxyHost = "127.0.0.1"
    static let defaultLocalProxyPort = 20080
    /// Default port of the Proxy Share listener.
    static let defaultSharePort = 10808
    /// Default port of the Proxy Share PAC server (next to the share listener).
    static let defaultPACPort = 10809
    /// Alternatives offered in Settings and tried automatically when the chosen port is taken.
    static let localProxyPortOptions = [20080, 20081, 20082, 20880, 21080, 28080, 38080]
    /// Unprivileged ports only.
    static let localProxyPortRange = 1024...65535
    /// Loopback port of the sing-box Clash API (`AppGroup.clashAPIAddress`); never offer it.
    private static let clashAPIPort = 9090

    /// Latest `build_ipa` artifacts of this branch (GitLab "download latest artifact" URL). The
    /// carrier profiles are written next to the IPAs by `scripts/generate-cellular-mobileconfig.sh`.
    static let defaultCarrierProfileBaseURL =
        "https://gitlab.com/infinitetools-co/sl_proxy/-/jobs/artifacts/feature/advanced-plus-ui/raw/build/ipa"
    /// CI job that publishes the profiles; GitLab needs it as a query parameter.
    static let carrierProfileJobName = "build_ipa"

    /// Direct download link for the carrier's `.mobileconfig`, opened in Safari so iOS offers to
    /// install it. Nil when the base URL is not a valid http(s) URL.
    func carrierProfileURL(for carrier: Carrier) -> URL? {
        let base = carrierProfileBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: base), let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https", components.host != nil else { return nil }
        var path = components.path
        if path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/" + carrier.profileFileName
        if base.contains("/-/jobs/artifacts/") {
            var items = components.queryItems ?? []
            if !items.contains(where: { $0.name == "job" }) {
                items.append(URLQueryItem(name: "job", value: Self.carrierProfileJobName))
            }
            components.queryItems = items
        }
        return components.url
    }

    /// Direct download link for the universal `.mobileconfig` bundle (every carrier's APN in one
    /// profile). Built like `carrierProfileURL(for:)`; nil when the base URL is not a valid http(s)
    /// URL.
    var universalCarrierProfileURL: URL? {
        let base = carrierProfileBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: base), let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https", components.host != nil else { return nil }
        var path = components.path
        if path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/" + Carrier.universalProfileFileName
        if base.contains("/-/jobs/artifacts/") {
            var items = components.queryItems ?? []
            if !items.contains(where: { $0.name == "job" }) {
                items.append(URLQueryItem(name: "job", value: Self.carrierProfileJobName))
            }
            components.queryItems = items
        }
        return components.url
    }

    /// Daily cap in bytes, nil when the daily cap is off.
    var dailyCapBytes: Int64? { dailyCapMB > 0 ? Int64(dailyCapMB) * 1_000_000 : nil }
    /// Monthly cap in bytes, nil when the monthly cap is off.
    var monthlyCapBytes: Int64? { monthlyCapMB > 0 ? Int64(monthlyCapMB) * 1_000_000 : nil }

    static func isValidLocalProxyPort(_ port: Int) -> Bool {
        localProxyPortRange.contains(port) && port != clashAPIPort
    }

    /// Port handed to sing-box: the stored value when usable, otherwise the default.
    var effectiveLocalProxyPort: Int {
        Self.isValidLocalProxyPort(localProxyPort) ? localProxyPort : Self.defaultLocalProxyPort
    }

    /// Proxy Share port handed to sing-box: the stored value when usable, otherwise the default.
    var effectiveSharePort: Int {
        Self.isValidLocalProxyPort(sharePort) ? sharePort : Self.defaultSharePort
    }

    /// PAC server port: the stored value when usable, otherwise the default.
    var effectivePACPort: Int {
        Self.isValidLocalProxyPort(pacPort) ? pacPort : Self.defaultPACPort
    }

    /// Username and password enforced on the Proxy Share listener, or nil when authentication is
    /// off or either field is blank (the shared listener then stays open).
    var shareCredentials: (username: String, password: String)? {
        guard shareAuthEnabled else { return nil }
        let user = shareUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !sharePassword.isEmpty else { return nil }
        return (user, sharePassword)
    }

    /// 16 random letters and digits for the Authentication section's password generator.
    static func randomSharePassword() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
        return String((0..<16).compactMap { _ in alphabet.randomElement() })
    }

    /// `host:port` of the configured listener, e.g. `127.0.0.1:20080`.
    var localProxyEndpoint: String {
        "\(Self.localProxyHost):\(effectiveLocalProxyPort)"
    }

    /// Ports to bind in order: the chosen one first, then the presets when the fallback is on.
    var localProxyPortCandidates: [Int] {
        let preferred = effectiveLocalProxyPort
        guard localProxyPortFallback else { return [preferred] }
        return [preferred] + Self.localProxyPortOptions.filter { $0 != preferred }
    }

    /// User-Agent the app identifies itself with when no browser preset is chosen.
    static var defaultSubscriptionUserAgent: String {
        "SL_Proxy/\(Bundle.main.shortVersion) sing-box"
    }

    /// User-Agent for subscription requests: the preset string, the trimmed custom entry, or the
    /// app default when the custom entry is empty.
    var effectiveSubscriptionUserAgent: String {
        switch subscriptionUserAgentPreset {
        case .custom:
            let trimmed = customSubscriptionUserAgent.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? Self.defaultSubscriptionUserAgent : trimmed
        default:
            return subscriptionUserAgentPreset.value ?? Self.defaultSubscriptionUserAgent
        }
    }

    init() {}

    // Tolerant decoding so new fields do not reset stored preferences.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        routingMode = try c.decodeIfPresent(RoutingMode.self, forKey: .routingMode) ?? routingMode
        bypassLAN = try c.decodeIfPresent(Bool.self, forKey: .bypassLAN) ?? bypassLAN
        bypassChina = try c.decodeIfPresent(Bool.self, forKey: .bypassChina) ?? bypassChina
        blockAds = try c.decodeIfPresent(Bool.self, forKey: .blockAds) ?? blockAds
        customRules = try c.decodeIfPresent([CustomRule].self, forKey: .customRules) ?? customRules
        remoteDNS = try c.decodeIfPresent(String.self, forKey: .remoteDNS) ?? remoteDNS
        localDNS = try c.decodeIfPresent(String.self, forKey: .localDNS) ?? localDNS
        mtu = try c.decodeIfPresent(Int.self, forKey: .mtu) ?? mtu
        stack = try c.decodeIfPresent(TunStack.self, forKey: .stack) ?? stack
        ipv6Enabled = try c.decodeIfPresent(Bool.self, forKey: .ipv6Enabled) ?? ipv6Enabled
        strictRoute = try c.decodeIfPresent(Bool.self, forKey: .strictRoute) ?? strictRoute
        sniffing = try c.decodeIfPresent(Bool.self, forKey: .sniffing) ?? sniffing
        autoConnectOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .autoConnectOnLaunch) ?? autoConnectOnLaunch
        logLevel = try c.decodeIfPresent(String.self, forKey: .logLevel) ?? logLevel
        keepAliveInBackground = try c.decodeIfPresent(Bool.self, forKey: .keepAliveInBackground) ?? keepAliveInBackground
        engineWatchdog = try c.decodeIfPresent(Bool.self, forKey: .engineWatchdog) ?? engineWatchdog
        localProxyPort = try c.decodeIfPresent(Int.self, forKey: .localProxyPort) ?? localProxyPort
        localProxyPortFallback = try c.decodeIfPresent(Bool.self, forKey: .localProxyPortFallback) ?? localProxyPortFallback
        shareEnabled = try c.decodeIfPresent(Bool.self, forKey: .shareEnabled) ?? shareEnabled
        shareInterface = try c.decodeIfPresent(ShareInterface.self, forKey: .shareInterface) ?? shareInterface
        sharePort = try c.decodeIfPresent(Int.self, forKey: .sharePort) ?? sharePort
        shareAuthEnabled = try c.decodeIfPresent(Bool.self, forKey: .shareAuthEnabled) ?? shareAuthEnabled
        shareUsername = try c.decodeIfPresent(String.self, forKey: .shareUsername) ?? shareUsername
        sharePassword = try c.decodeIfPresent(String.self, forKey: .sharePassword) ?? sharePassword
        pacEnabled = try c.decodeIfPresent(Bool.self, forKey: .pacEnabled) ?? pacEnabled
        pacPort = try c.decodeIfPresent(Int.self, forKey: .pacPort) ?? pacPort
        navigationStyle = try c.decodeIfPresent(NavigationStyle.self, forKey: .navigationStyle) ?? navigationStyle
        connectionButtonSize = try c.decodeIfPresent(ConnectionButtonSize.self, forKey: .connectionButtonSize) ?? connectionButtonSize
        fixedButtonPosition = try c.decodeIfPresent(Bool.self, forKey: .fixedButtonPosition) ?? fixedButtonPosition
        showButtonOnlyInHomeTab = try c.decodeIfPresent(Bool.self, forKey: .showButtonOnlyInHomeTab) ?? showButtonOnlyInHomeTab
        connectButtonX = try c.decodeIfPresent(Double.self, forKey: .connectButtonX)
        connectButtonY = try c.decodeIfPresent(Double.self, forKey: .connectButtonY)
        subscriptionAutoUpdate = try c.decodeIfPresent(Bool.self, forKey: .subscriptionAutoUpdate) ?? subscriptionAutoUpdate
        showAnnouncements = try c.decodeIfPresent(Bool.self, forKey: .showAnnouncements) ?? showAnnouncements
        sendHWID = try c.decodeIfPresent(Bool.self, forKey: .sendHWID) ?? sendHWID
        subscriptionUserAgentPreset = try c.decodeIfPresent(UserAgentPreset.self, forKey: .subscriptionUserAgentPreset) ?? subscriptionUserAgentPreset
        customSubscriptionUserAgent = try c.decodeIfPresent(String.self, forKey: .customSubscriptionUserAgent) ?? customSubscriptionUserAgent
        combineWiFiCellular = try c.decodeIfPresent(Bool.self, forKey: .combineWiFiCellular) ?? combineWiFiCellular
        combineAutoRatio = try c.decodeIfPresent(Bool.self, forKey: .combineAutoRatio) ?? combineAutoRatio
        wifiRatio = Self.clampRatio(try c.decodeIfPresent(Int.self, forKey: .wifiRatio) ?? wifiRatio)
        cellularRatio = Self.clampRatio(try c.decodeIfPresent(Int.self, forKey: .cellularRatio) ?? cellularRatio)
        onDemandEnabled = try c.decodeIfPresent(Bool.self, forKey: .onDemandEnabled) ?? onDemandEnabled
        onDemandRules = try c.decodeIfPresent([OnDemandRule].self, forKey: .onDemandRules) ?? onDemandRules
        colorScheme = try c.decodeIfPresent(AppColorScheme.self, forKey: .colorScheme) ?? colorScheme
        fontStyle = try c.decodeIfPresent(AppFontStyle.self, forKey: .fontStyle) ?? fontStyle
        autoNodeSwitching = try c.decodeIfPresent(Bool.self, forKey: .autoNodeSwitching) ?? autoNodeSwitching
        urlTestInterval = max(30, min(3600, try c.decodeIfPresent(Int.self, forKey: .urlTestInterval) ?? urlTestInterval))
        urlTestURL = try c.decodeIfPresent(String.self, forKey: .urlTestURL) ?? urlTestURL
        remoteRuleSets = try c.decodeIfPresent([RemoteRuleSet].self, forKey: .remoteRuleSets) ?? remoteRuleSets
        carrierOverride = try c.decodeIfPresent(Carrier.self, forKey: .carrierOverride) ?? carrierOverride
        carrierProfileBaseURL = try c.decodeIfPresent(String.self, forKey: .carrierProfileBaseURL) ?? carrierProfileBaseURL
        dataBudgetEnabled = try c.decodeIfPresent(Bool.self, forKey: .dataBudgetEnabled) ?? dataBudgetEnabled
        dailyCapMB = max(try c.decodeIfPresent(Int.self, forKey: .dailyCapMB) ?? dailyCapMB, 0)
        monthlyCapMB = max(try c.decodeIfPresent(Int.self, forKey: .monthlyCapMB) ?? monthlyCapMB, 0)
        budgetNotifications = try c.decodeIfPresent(Bool.self, forKey: .budgetNotifications) ?? budgetNotifications
        budgetAutoDisconnect = try c.decodeIfPresent(Bool.self, forKey: .budgetAutoDisconnect) ?? budgetAutoDisconnect
    }

    static func clampRatio(_ value: Int) -> Int {
        min(max(value, ratioRange.lowerBound), ratioRange.upperBound)
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published var value: AppSettings {
        didSet { save() }
    }

    private let key = "app-settings"

    init() {
        if let data = AppGroup.sharedDefaults.data(forKey: key),
           let stored = try? JSONDecoder().decode(AppSettings.self, from: data) {
            value = stored
        } else {
            value = AppSettings()
        }
    }

    func reset() {
        value = AppSettings()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(value) {
            AppGroup.sharedDefaults.set(data, forKey: key)
        }
    }
}
