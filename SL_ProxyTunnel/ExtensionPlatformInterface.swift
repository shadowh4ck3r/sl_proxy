import Foundation
import Network
import NetworkExtension
#if canImport(Libbox)
import Libbox

/// Bridges sing-box (Libbox) platform callbacks to the Network Extension APIs.
/// Modelled on the reference sing-box Apple client for sing-box 1.11.
final class ExtensionPlatformInterface: NSObject, LibboxPlatformInterfaceProtocol {
    private unowned let provider: PacketTunnelProvider
    private var pathMonitor: NWPathMonitor?
    private var interfaceListener: LibboxInterfaceUpdateListenerProtocol?
    private let monitorQueue = DispatchQueue(label: "com.slproxy.app.tunnel.path-monitor")

    init(provider: PacketTunnelProvider) {
        self.provider = provider
        super.init()
    }

    func reset() {
        pathMonitor?.cancel()
        pathMonitor = nil
        interfaceListener = nil
    }

    // MARK: - TUN

    func openTun(_ options: (any LibboxTunOptionsProtocol)?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        guard let options else { throw PlatformError.message("Missing TUN options") }
        guard let ret0_ else { throw PlatformError.message("Missing TUN return pointer") }

        let settings = try makeNetworkSettings(options)

        // Libbox calls this from a Go thread, so block until the system applied the settings.
        let semaphore = DispatchSemaphore(value: 0)
        var applyError: Error?
        provider.setTunnelNetworkSettings(settings) { error in
            applyError = error
            semaphore.signal()
        }
        semaphore.wait()
        if let applyError { throw applyError }

        guard let fd = provider.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 else {
            throw PlatformError.message("Unable to obtain the tunnel file descriptor")
        }
        ret0_.pointee = fd
        provider.record("TUN ready (fd \(fd), mtu \(options.getMTU()))")
    }

    private func makeNetworkSettings(_ options: any LibboxTunOptionsProtocol) throws -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = NSNumber(value: options.getMTU())

        let dnsServer = try options.getDNSServerAddress()
        let dns = NEDNSSettings(servers: [dnsServer.value])
        dns.matchDomains = [""]
        settings.dnsSettings = dns

        // IPv4
        var v4Addresses: [String] = []
        var v4Masks: [String] = []
        if let iterator = options.getInet4Address() {
            while iterator.hasNext() {
                guard let prefix = iterator.next() else { break }
                v4Addresses.append(prefix.address())
                v4Masks.append(prefix.mask())
            }
        }
        if !v4Addresses.isEmpty {
            let v4 = NEIPv4Settings(addresses: v4Addresses, subnetMasks: v4Masks)
            var included: [NEIPv4Route] = []
            if let iterator = options.getInet4RouteAddress() {
                while iterator.hasNext() {
                    guard let prefix = iterator.next() else { break }
                    included.append(NEIPv4Route(destinationAddress: prefix.address(), subnetMask: prefix.mask()))
                }
            }
            if included.isEmpty { included = [NEIPv4Route.default()] }
            v4.includedRoutes = included

            var excluded: [NEIPv4Route] = []
            if let iterator = options.getInet4RouteExcludeAddress() {
                while iterator.hasNext() {
                    guard let prefix = iterator.next() else { break }
                    excluded.append(NEIPv4Route(destinationAddress: prefix.address(), subnetMask: prefix.mask()))
                }
            }
            // Keep the proxy server itself outside the TUN so its handshake cannot loop back in.
            if let host = provider.endpoint?.host, IPv4Address(host) != nil {
                excluded.append(NEIPv4Route(destinationAddress: host, subnetMask: "255.255.255.255"))
            }
            v4.excludedRoutes = excluded
            settings.ipv4Settings = v4
        }

        // IPv6
        var v6Addresses: [String] = []
        var v6Prefixes: [NSNumber] = []
        if let iterator = options.getInet6Address() {
            while iterator.hasNext() {
                guard let prefix = iterator.next() else { break }
                v6Addresses.append(prefix.address())
                v6Prefixes.append(NSNumber(value: prefix.prefix()))
            }
        }
        if !v6Addresses.isEmpty {
            let v6 = NEIPv6Settings(addresses: v6Addresses, networkPrefixLengths: v6Prefixes)
            var included: [NEIPv6Route] = []
            if let iterator = options.getInet6RouteAddress() {
                while iterator.hasNext() {
                    guard let prefix = iterator.next() else { break }
                    included.append(NEIPv6Route(destinationAddress: prefix.address(), networkPrefixLength: NSNumber(value: prefix.prefix())))
                }
            }
            if included.isEmpty { included = [NEIPv6Route.default()] }
            v6.includedRoutes = included

            var excluded: [NEIPv6Route] = []
            if let iterator = options.getInet6RouteExcludeAddress() {
                while iterator.hasNext() {
                    guard let prefix = iterator.next() else { break }
                    excluded.append(NEIPv6Route(destinationAddress: prefix.address(), networkPrefixLength: NSNumber(value: prefix.prefix())))
                }
            }
            if let host = provider.endpoint?.host, IPv6Address(host) != nil {
                excluded.append(NEIPv6Route(destinationAddress: host, networkPrefixLength: 128))
            }
            v6.excludedRoutes = excluded
            settings.ipv6Settings = v6
        }

        if options.isHTTPProxyEnabled() {
            let proxy = NEProxySettings()
            let server = NEProxyServer(address: options.getHTTPProxyServer(), port: Int(options.getHTTPProxyServerPort()))
            proxy.httpEnabled = true
            proxy.httpServer = server
            proxy.httpsEnabled = true
            proxy.httpsServer = server
            settings.proxySettings = proxy
        }

        return settings
    }

    // MARK: - Default interface monitor

    func usePlatformDefaultInterfaceMonitor() -> Bool { true }

    func startDefaultInterfaceMonitor(_ listener: (any LibboxInterfaceUpdateListenerProtocol)?) throws {
        guard let listener else { return }
        interfaceListener = listener
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handlePathUpdate(path)
        }
        monitor.start(queue: monitorQueue)
        pathMonitor = monitor
    }

    func closeDefaultInterfaceMonitor(_ listener: (any LibboxInterfaceUpdateListenerProtocol)?) throws {
        reset()
    }

    private func handlePathUpdate(_ path: Network.NWPath) {
        guard let listener = interfaceListener else { return }
        // Once the TUN is up the first interface is often utun itself; handing that to sing-box makes
        // it bind outbound sockets to the tunnel and the proxy handshake loops back into the TUN.
        guard path.status == .satisfied,
              let interface = path.availableInterfaces.first(where: {
                  !$0.name.hasPrefix("utun") && !$0.name.hasPrefix("ipsec") && $0.type != .loopback
              }) else {
            listener.updateDefaultInterface("", interfaceIndex: -1, isExpensive: false, isConstrained: false)
            return
        }
        listener.updateDefaultInterface(
            interface.name,
            interfaceIndex: Int32(interface.index),
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
    }

    // MARK: - Interface control

    func usePlatformAutoDetectControl() -> Bool { true }

    func autoDetectControl(_ fd: Int32) throws {
        // The system binds extension sockets to the physical interface; nothing to do.
    }

    func usePlatformInterfaceGetter() -> Bool { false }

    func getInterfaces() throws -> any LibboxNetworkInterfaceIteratorProtocol {
        throw PlatformError.message("Platform interface getter is not used")
    }

    // MARK: - Process lookup (Android only)

    func useProcFS() -> Bool { false }

    func findConnectionOwner(
        _ ipProtocol: Int32, sourceAddress: String?, sourcePort: Int32,
        destinationAddress: String?, destinationPort: Int32, ret0_: UnsafeMutablePointer<Int32>?
    ) throws {
        throw PlatformError.message("Connection owner lookup is not supported on iOS")
    }

    func packageName(byUid uid: Int32, error: NSErrorPointer) -> String { "" }

    func uid(byPackageName packageName: String?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        throw PlatformError.message("Package lookup is not supported on iOS")
    }

    // MARK: - Misc

    func underNetworkExtension() -> Bool { true }

    func includeAllNetworks() -> Bool { false }

    func readWIFIState() -> LibboxWIFIState? { nil }

    func clearDNSCache() {}

    func send(_ notification: LibboxNotification?) throws {}

    func writeLog(_ message: String?) {
        guard let message, !message.isEmpty else { return }
        provider.record(message)
    }

    enum PlatformError: LocalizedError {
        case message(String)

        var errorDescription: String? {
            switch self {
            case .message(let text): return text
            }
        }
    }
}
#endif
