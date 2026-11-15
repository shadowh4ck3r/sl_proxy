import Combine
import Foundation
import Network

/// Publishes the device's current network path (`NWPathMonitor`) for the features that need to
/// know whether traffic rides cellular or Wi-Fi: the carrier profile verifier, the cellular data
/// budget and the On-Demand engine. One shared monitor serves every subscriber.
@MainActor
final class NetworkPathObserver: ObservableObject {
    static let shared = NetworkPathObserver()

    @Published private(set) var isSatisfied = false
    /// True when the default route is cellular and Wi-Fi is not part of the path.
    @Published private(set) var isCellular = false
    @Published private(set) var isWiFi = false
    @Published private(set) var isExpensive = false
    /// BSD name of the first non-loopback interface on the path (`en0`, `pdp_ip0`, ...).
    @Published private(set) var interfaceName: String?
    @Published private(set) var lastChange: Date?

    private struct Snapshot: Sendable {
        let satisfied: Bool
        let cellular: Bool
        let wifi: Bool
        let expensive: Bool
        let interfaceName: String?
    }

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.slproxy.userspace.path-observer")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let snapshot = Snapshot(
                satisfied: path.status == .satisfied,
                cellular: path.usesInterfaceType(.cellular) && !path.usesInterfaceType(.wifi) && !path.usesInterfaceType(.wiredEthernet),
                wifi: path.usesInterfaceType(.wifi),
                expensive: path.isExpensive,
                interfaceName: path.availableInterfaces.first { $0.type != .loopback }?.name
            )
            Task { @MainActor [weak self] in
                self?.apply(snapshot)
            }
        }
        monitor.start(queue: queue)
    }

    /// One-word description for diagnostics rows.
    var summary: String {
        guard isSatisfied else { return "Offline" }
        if isCellular { return "Cellular" }
        if isWiFi { return "Wi-Fi" }
        return "Other"
    }

    private func apply(_ snapshot: Snapshot) {
        let changed = snapshot.satisfied != isSatisfied || snapshot.cellular != isCellular
            || snapshot.wifi != isWiFi || snapshot.interfaceName != interfaceName
        isSatisfied = snapshot.satisfied
        isCellular = snapshot.cellular
        isWiFi = snapshot.wifi
        isExpensive = snapshot.expensive
        interfaceName = snapshot.interfaceName
        if changed { lastChange = Date() }
    }
}
