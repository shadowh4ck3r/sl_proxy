import Network
import NetworkExtension
import OSLog
#if canImport(Libbox)
import Libbox
#endif

// CI builds with REQUIRE_LIBBOX. Without this, a target that cannot see Libbox.xcframework
// compiles the core-less fallback below and ships a tunnel that never proxies anything.
#if REQUIRE_LIBBOX && !canImport(Libbox)
#error("Libbox.xcframework is not visible to the SL_ProxyTunnel target; check Frameworks/Libbox.xcframework and FRAMEWORK_SEARCH_PATHS in project.yml")
#endif

/// System VPN provider for SL_Proxy. Runs the sing-box core (Libbox) on the configuration the
/// app hands over through the VPN profile (`providerConfiguration`), the start options or, as a
/// last resort, the App Group container. Nothing here requires the App Group entitlement.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = Logger(subsystem: AppGroup.tunnelBundleID, category: "tunnel")
    private let logs = TunnelLogBuffer.shared
    private var startedAt: Date?
    private var lastError: String?
    private var configSource: String?
    /// Server parsed from the raw import string; used to keep the proxy itself outside the TUN.
    private(set) var endpoint: ProxyEndpoint?

    #if canImport(Libbox)
    private var service: LibboxBoxService?
    private var platform: ExtensionPlatformInterface?
    #endif

    // MARK: - Lifecycle

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        lastError = nil
        record("Starting tunnel")
        record(AppGroup.isAvailable
            ? "App Group: \(AppGroup.identifier)"
            : "App Group unavailable (common after re-signing); using the extension sandbox")

        // 1. Raw import string: VPN profile first (survives app termination), start options second.
        let raw: String
        do {
            let loaded = try loadRawConfig(options: options)
            raw = loaded.config
            configSource = loaded.source
            record("Configuration loaded from \(loaded.source) (\(raw.utf8.count) bytes)")
        } catch {
            completionHandler(startFailure(error))
            return
        }

        // 2. Safe parse. Credentials never reach the log.
        guard let endpoint = ProxyEndpoint.parse(raw) else {
            completionHandler(startFailure(TunnelError.malformedConfig))
            return
        }
        self.endpoint = endpoint
        record("Proxy \(endpoint.scheme)://\(endpoint.label), credentials \(endpoint.secret == nil ? "absent" : "present")")

        // 3. The sing-box JSON the app generated. The raw string doubles as the core config only
        //    when it is JSON itself (hand-entered servers).
        guard let coreConfig = loadCoreConfig(options: options) ?? (raw.hasPrefix("{") ? raw : nil) else {
            completionHandler(startFailure(TunnelError.noCoreConfig))
            return
        }

        #if canImport(Libbox)
        // Libbox invokes openTun() during start(); openTun applies the NEPacketTunnelNetworkSettings
        // and blocks until the system confirms them. start() therefore returns only after the
        // settings are live, and completionHandler(nil) fires strictly after that.
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                try setupCore()
                let platform = ExtensionPlatformInterface(provider: self)
                self.platform = platform
                var creationError: NSError?
                guard let service = LibboxNewService(coreConfig, platform, &creationError) else {
                    throw creationError ?? TunnelError.coreUnavailable
                }
                try service.start()
                self.service = service
                startedAt = Date()
                record("sing-box core started")
                completionHandler(nil)
            } catch {
                platform?.reset()
                platform = nil
                service = nil
                completionHandler(startFailure(error))
            }
        }
        #else
        // 4. Libbox is not linked in this build: apply the settings directly and complete only once
        //    the system confirms them. Nothing reads the TUN without the core, so this is diagnostic.
        let settings = makeNetworkSettings(excluding: endpoint)
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else {
                completionHandler(error)
                return
            }
            if let error {
                completionHandler(self.startFailure(error))
                return
            }
            self.startedAt = Date()
            self.record("Tunnel started without the sing-box core (Libbox not linked in this build)")
            completionHandler(nil)
        }
        #endif
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        record("Stopping tunnel (reason \(reason.rawValue))")
        #if canImport(Libbox)
        if let service {
            do {
                try service.close()
            } catch {
                record("Core close error: \(error.localizedDescription)")
            }
        }
        service = nil
        platform?.reset()
        platform = nil
        #endif
        startedAt = nil
    }

    override func sleep() async {
        #if canImport(Libbox)
        service?.pause()
        #endif
    }

    override func wake() {
        #if canImport(Libbox)
        service?.wake()
        #endif
    }

    // MARK: - App <-> tunnel IPC

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        guard let request = try? JSONDecoder().decode(TunnelRequest.self, from: messageData) else {
            return nil
        }
        var reply = TunnelReply(running: startedAt != nil, startedAt: startedAt, lastError: lastError)
        reply.appGroupAvailable = AppGroup.isAvailable
        reply.configSource = configSource
        switch request {
        case .status:
            break
        case .logs(let after):
            let page = logs.lines(after: after)
            reply.logs = page.lines
            reply.nextLogIndex = page.next
        case .clearLogs:
            logs.clear()
        }
        return try? JSONEncoder().encode(reply)
    }

    // MARK: - Configuration

    /// Resolution order for the raw import string: VPN profile (survives app termination and
    /// on-demand starts), start options, generated core config (older profiles), App Group file.
    private func loadRawConfig(options: [String: NSObject]?) throws -> (config: String, source: String) {
        let proto = protocolConfiguration as? NETunnelProviderProtocol
        if let raw = proto?.providerConfiguration?[AppGroup.ProviderKey.rawConfigData] as? String, !raw.isEmpty {
            return (raw, "VPN profile")
        }
        if let raw = options?[AppGroup.ProviderKey.rawConfigData] as? String, !raw.isEmpty {
            return (raw, "start options")
        }
        if let json = loadCoreConfig(options: options) {
            return (json, "VPN profile (core config)")
        }
        if let url = AppGroup.activeConfigURL, FileManager.default.fileExists(atPath: url.path) {
            return (try String(contentsOf: url, encoding: .utf8), "App Group file")
        }
        throw TunnelError.noActiveConfig
    }

    /// Generated sing-box JSON: start options (freshest) then the VPN profile.
    private func loadCoreConfig(options: [String: NSObject]?) -> String? {
        if let config = options?[AppGroup.ProviderKey.config] as? String, !config.isEmpty {
            return config
        }
        if let proto = protocolConfiguration as? NETunnelProviderProtocol,
           let config = proto.providerConfiguration?[AppGroup.ProviderKey.config] as? String,
           !config.isEmpty {
            return config
        }
        return nil
    }

    /// Full-tunnel settings that keep the proxy server itself reachable outside the TUN.
    func makeNetworkSettings(excluding endpoint: ProxyEndpoint, mtu: Int = 1500) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "172.19.0.1")
        settings.mtu = NSNumber(value: mtu)

        let ipv4 = NEIPv4Settings(addresses: ["172.19.0.2"], subnetMasks: ["255.255.255.252"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        if IPv4Address(endpoint.host) != nil {
            ipv4.excludedRoutes = [NEIPv4Route(destinationAddress: endpoint.host, subnetMask: "255.255.255.255")]
        }
        settings.ipv4Settings = ipv4

        if IPv6Address(endpoint.host) != nil {
            let ipv6 = NEIPv6Settings(addresses: ["fdfe:dcba:9876::2"], networkPrefixLengths: [126])
            ipv6.includedRoutes = [NEIPv6Route.default()]
            ipv6.excludedRoutes = [NEIPv6Route(destinationAddress: endpoint.host, networkPrefixLength: 128)]
            settings.ipv6Settings = ipv6
        }

        let dns = NEDNSSettings(servers: ["1.1.1.1", "8.8.8.8"])
        dns.matchDomains = [""]
        settings.dnsSettings = dns
        return settings
    }

    /// Storage private to the extension, used when no App Group container is available.
    private func sandboxBaseURL() -> URL {
        let fm = FileManager.default
        let root = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        return root.appendingPathComponent("SL_Proxy", isDirectory: true)
    }

    // MARK: - Helpers

    #if canImport(Libbox)
    private func setupCore() throws {
        let fm = FileManager.default
        let base = AppGroup.containerURL ?? sandboxBaseURL()
        let working = base.appendingPathComponent("core", isDirectory: true)
        try fm.createDirectory(at: working, withIntermediateDirectories: true)
        record("Core working directory: \(working.path)")

        let options = LibboxSetupOptions()
        options.basePath = base.path
        options.workingPath = working.path
        options.tempPath = fm.temporaryDirectory.path
        options.isTVOS = false
        var setupError: NSError?
        if !LibboxSetup(options, &setupError) {
            throw setupError ?? TunnelError.coreUnavailable
        }
        LibboxSetMemoryLimit(true)
    }
    #endif

    /// Writes to the unified log and to the buffer served to the app.
    func record(_ message: String) {
        log.info("\(message, privacy: .public)")
        logs.append(message)
    }

    private func fail(_ error: Error) {
        lastError = error.localizedDescription
        record("Error: \(error.localizedDescription)")
    }

    /// Records the failure and returns the error handed to the system. iOS kills this process right
    /// after a failed start, so the last log lines ride along in the description; the app reads
    /// them back through `NEVPNConnection.fetchLastDisconnectError`.
    private func startFailure(_ error: Error) -> NSError {
        fail(error)
        let tail = logs.tail(8).joined(separator: "\n")
        let description = "\(error.localizedDescription)\n\nTunnel log:\n\(tail)"
        return NSError(
            domain: AppGroup.tunnelBundleID,
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }

    enum TunnelError: LocalizedError {
        case noActiveConfig
        case malformedConfig
        case noCoreConfig
        case coreUnavailable

        var errorDescription: String? {
            switch self {
            case .noActiveConfig:
                return "No proxy configuration reached the tunnel. Select a server in SL_Proxy and connect again."
            case .malformedConfig:
                return "The imported config has no readable server address or port."
            case .noCoreConfig:
                return "The tunnel received a share link but no generated core configuration. Reconnect from SL_Proxy."
            case .coreUnavailable:
                return "The sing-box core failed to initialise."
            }
        }
    }
}
