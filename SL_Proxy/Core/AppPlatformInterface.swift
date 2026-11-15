import Foundation
import Network
#if canImport(Libbox)
import Libbox

/// Bridges sing-box (Libbox) platform callbacks for the in-app, user-space engine.
///
/// Same contract as `ExtensionPlatformInterface` in the system VPN build on `main`, minus the TUN:
/// the loopback build only has a `mixed` inbound, so sing-box never asks for a device and the
/// process is a plain app, not a Network Extension.
final class AppPlatformInterface: NSObject, LibboxPlatformInterfaceProtocol {
    private unowned let engine: LocalProxyEngine
    private var pathMonitor: NWPathMonitor?
    private var interfaceListener: LibboxInterfaceUpdateListenerProtocol?
    private let monitorQueue = DispatchQueue(label: "com.slproxy.userspace.path-monitor")

    init(engine: LocalProxyEngine) {
        self.engine = engine
        super.init()
    }

    func reset() {
        pathMonitor?.cancel()
        pathMonitor = nil
        interfaceListener = nil
    }

    // MARK: - TUN (not available without the Network Extension)

    func openTun(_ options: (any LibboxTunOptionsProtocol)?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        throw PlatformError.message(
            "A TUN inbound needs the system VPN build; the user-space build only serves the mixed inbound on \(engine.endpointDescription)"
        )
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

    /// Informational only: the user-space config sets `route.auto_detect_interface` to false, so
    /// sing-box never binds outbound sockets to what is reported here. Prefer the physical network
    /// over loopback and any VPN interface another app may have up, but never report "no
    /// interface" while a path exists; that is what made every dial fail with
    /// "no available network interface".
    private func handlePathUpdate(_ path: Network.NWPath) {
        guard let listener = interfaceListener else { return }
        guard path.status == .satisfied else {
            listener.updateDefaultInterface("", interfaceIndex: -1, isExpensive: false, isConstrained: false)
            return
        }
        let candidates = path.availableInterfaces.filter { $0.type != .loopback }
        guard let interface = candidates.first(where: {
            !$0.name.hasPrefix("utun") && !$0.name.hasPrefix("ipsec")
        }) ?? candidates.first else {
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

    /// Off: the core must not route socket control through the app. The user-space config also
    /// disables `route.auto_detect_interface`, so sing-box dials with plain sockets that follow
    /// the system default route instead of asking for an interface.
    func usePlatformAutoDetectControl() -> Bool { false }

    func autoDetectControl(_ fd: Int32) throws {
        // No TUN exists in this process, so sockets already leave through the default route.
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

    func underNetworkExtension() -> Bool { false }

    func includeAllNetworks() -> Bool { false }

    func readWIFIState() -> LibboxWIFIState? { nil }

    func clearDNSCache() {}

    func send(_ notification: LibboxNotification?) throws {}

    func writeLog(_ message: String?) {
        guard let message, !message.isEmpty else { return }
        engine.record(message)
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
