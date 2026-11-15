import Foundation

/// Identifiers and shared storage locations used by both the app and the tunnel extension.
///
/// `defaultIdentifier` must match `com.apple.security.application-groups` in BOTH targets'
/// entitlements (written by `scripts/setup-app-group.sh`, which also rewrites this constant).
/// The TrollStore IPA carries the group in its ad-hoc signature, so the container exists there.
///
/// Sideloading tools (Sideloadly, AltStore, ESign, ...) re-sign the IPA with a personal
/// certificate and frequently drop or rename the App Group entitlement. Everything here is
/// therefore best-effort: the group is used when it works, and every caller must keep going
/// when `containerURL` is nil. The tunnel receives its configuration through the VPN profile
/// (`NETunnelProviderProtocol.providerConfiguration`), which needs no App Group at all.
enum AppGroup {
    static let defaultIdentifier = "group.sailorsloot.proxy"
    static let appBundleID = "com.slproxy.app"
    static let tunnelBundleID = "com.slproxy.app.tunnel"

    /// sing-box JSON mirrored into the container (when available) as a fallback for the tunnel.
    static let activeConfigFileName = "active-config.json"

    /// Loopback address of the sing-box Clash API. The app streams live traffic
    /// statistics from it while the tunnel is running.
    static let clashAPIAddress = "127.0.0.1:9090"

    /// Keys used in `NETunnelProviderProtocol.providerConfiguration` and `startVPNTunnel(options:)`.
    enum ProviderKey {
        /// Generated sing-box JSON.
        static let config = "config"
        /// The share link exactly as the user imported it (or the JSON for hand-entered servers).
        static let rawConfigData = "rawConfigData"
        static let nodeName = "nodeName"
        static let generatedAt = "generatedAt"
    }

    /// App Group identifier that actually resolves to a usable container in this process.
    /// Falls back to `defaultIdentifier` when none does.
    static var identifier: String { resolution.identifier }

    /// True when a shared container exists and is writable.
    static var isAvailable: Bool { resolution.container != nil }

    static var containerURL: URL? { resolution.container }

    static var activeConfigURL: URL? {
        containerURL?.appendingPathComponent(activeConfigFileName, isDirectory: false)
    }

    /// Working directory handed to the sing-box core (cache database, downloaded rule sets).
    static var coreWorkingURL: URL? {
        containerURL?.appendingPathComponent("core", isDirectory: true)
    }

    /// Defaults shared between the app and the extension when the App Group exists. Without the
    /// entitlement an unentitled suite silently refuses to persist, so use the process's own defaults.
    static var sharedDefaults: UserDefaults {
        guard isAvailable, let defaults = UserDefaults(suiteName: identifier) else { return .standard }
        return defaults
    }

    /// One-line summary for the diagnostics UI and tunnel logs.
    static var statusDescription: String {
        if isAvailable { return "Available (\(identifier))" }
        return "Unavailable (tried \(resolution.tried.joined(separator: ", ")))"
    }

    // MARK: - Resolution

    private struct Resolution {
        let identifier: String
        let container: URL?
        let tried: [String]
    }

    private static let resolution: Resolution = resolve()

    private static func resolve() -> Resolution {
        let entitled = entitledGroups()
        var candidates = entitled.filter {
            let name = $0.lowercased()
            return name.contains("sailorsloot") || name.contains("slproxy")
        }
        candidates.append(contentsOf: entitled)
        candidates.append(defaultIdentifier)

        var seen = Set<String>()
        let unique = candidates.filter { seen.insert($0).inserted }

        for candidate in unique {
            if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: candidate),
               isWritable(url) {
                return Resolution(identifier: candidate, container: url, tried: unique)
            }
        }
        return Resolution(identifier: defaultIdentifier, container: nil, tried: unique)
    }

    private static func isWritable(_ url: URL) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            return false
        }
        let probe = url.appendingPathComponent(".slproxy-probe", isDirectory: false)
        guard fm.createFile(atPath: probe.path, contents: Data()) else { return false }
        try? fm.removeItem(at: probe)
        return true
    }

    /// App Groups granted by the provisioning profile this bundle was signed with. Re-signing
    /// tools rewrite the group name (for example `group.<TEAMID>.com.slproxy.app`), and this is
    /// the only public way to discover the name they chose.
    private static func entitledGroups() -> [String] {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<plist".utf8)),
              let end = data.range(of: Data("</plist>".utf8), options: [], in: start.upperBound..<data.endIndex) else {
            return []
        }
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String] else {
            return []
        }
        return groups
    }
}
