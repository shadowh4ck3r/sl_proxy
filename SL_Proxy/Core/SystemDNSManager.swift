import Foundation
import NetworkExtension

/// Optional "System Encrypted DNS (No VPN Icon)": mirrors the Remote DNS chosen in DNS Settings
/// into iOS itself through `NEDNSSettingsManager`, so other apps and the system resolve over
/// DoH / DoT without a VPN icon in the status bar.
///
/// Needs the `com.apple.developer.networking.networkextension` entitlement with the `dns-settings`
/// value. It is added to `Signing/MainApp.entitlements` (the TrollStore IPA) only; free Apple ID
/// signing cannot provision it, so there `apply` reports the missing entitlement instead of
/// failing silently. iOS then asks the user to switch the profile on under Settings > General >
/// VPN & Device Management > DNS.
@MainActor
final class SystemDNSManager: ObservableObject {
    /// Nil until the first `refresh()`; false means saved but not switched on in iOS Settings.
    @Published private(set) var isEnabled: Bool?
    @Published private(set) var message: String?
    @Published private(set) var isBusy = false

    private static let profileName = "SL_Proxy Encrypted DNS"

    /// Public resolvers whose IP addresses iOS needs next to the DoH / DoT host name.
    private static let knownServers: [String: [String]] = [
        "cloudflare-dns.com": ["1.1.1.1", "1.0.0.1"],
        "one.one.one.one": ["1.1.1.1", "1.0.0.1"],
        "dns.google": ["8.8.8.8", "8.8.4.4"],
        "dns.quad9.net": ["9.9.9.9", "149.112.112.112"],
        "dns.adguard-dns.com": ["94.140.14.14", "94.140.15.15"],
        "dns.adguard.com": ["94.140.14.14", "94.140.15.15"],
    ]

    func refresh() async {
        let manager = NEDNSSettingsManager.shared()
        do {
            try await manager.loadFromPreferences()
            isEnabled = manager.isEnabled && manager.dnsSettings != nil
        } catch {
            message = Self.describe(error)
        }
    }

    /// Saves the DoH / DoT profile for `remoteDNS`. `isEnabled` stays false until the user turns
    /// it on in iOS Settings.
    func apply(remoteDNS: String) async {
        guard let settings = Self.settings(for: remoteDNS) else {
            message = "Remote DNS \(remoteDNS) is not encrypted. Choose a DoH (https://) or DoT (tls://) server first."
            return
        }
        isBusy = true
        defer { isBusy = false }
        let manager = NEDNSSettingsManager.shared()
        do {
            try await manager.loadFromPreferences()
            manager.localizedDescription = Self.profileName
            manager.dnsSettings = settings
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            isEnabled = manager.isEnabled
            message = manager.isEnabled
                ? nil
                : "Saved. Turn it on under iOS Settings > General > VPN & Device Management > DNS."
        } catch {
            message = Self.describe(error)
        }
    }

    func remove() async {
        isBusy = true
        defer { isBusy = false }
        let manager = NEDNSSettingsManager.shared()
        do {
            try await manager.loadFromPreferences()
            try await manager.removeFromPreferences()
            isEnabled = false
            message = nil
        } catch {
            message = Self.describe(error)
        }
    }

    // MARK: - Mapping

    /// DoH for `https://` addresses, DoT for `tls://` ones; nil for plain UDP / local / unknown
    /// hosts whose IP addresses cannot be determined.
    static func settings(for remoteDNS: String) -> NEDNSSettings? {
        let raw = remoteDNS.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), let host = url.host else { return nil }
        let servers = ipv4Literal(host) ? [host] : (knownServers[host.lowercased()] ?? [])
        guard !servers.isEmpty else { return nil }
        switch scheme {
        case "https":
            let settings = NEDNSOverHTTPSSettings(servers: servers)
            settings.serverURL = url
            return settings
        case "tls":
            let settings = NEDNSOverTLSSettings(servers: servers)
            settings.serverName = host
            return settings
        default:
            return nil
        }
    }

    private static func ipv4Literal(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.localizedDescription.lowercased().contains("entitlement")
            || ns.localizedDescription.lowercased().contains("permission") {
            return "This build is not signed with the DNS Settings entitlement (dns-settings), so iOS refused the profile."
        }
        return ns.localizedDescription
    }
}
