import Combine
import Foundation

/// Confirms that the installed carrier profile is steering cellular data into the loopback
/// listener.
///
/// The `com.apple.cellular` profile points the APN proxy at 127.0.0.1:<port>, so while the device
/// is on cellular every app's traffic should arrive at the `mixed-in` inbound from a loopback
/// source. The verifier runs while the engine is up: it probes the listener socket and polls the
/// sing-box Clash API connection table every two seconds, looking for loopback connections on
/// `mixed-in` whose byte counters move while `NetworkPathObserver` reports cellular. A hit marks the
/// profile verified for `freshness` seconds; Home shows the green badge while that holds.
///
/// The badge also re-evaluates on every cellular/Wi-Fi path change, and `refresh()` runs one probe
/// immediately (the refresh button next to "Awaiting cellular traffic").
@MainActor
final class ProfileVerifier: ObservableObject {
    enum State: Equatable {
        /// Engine stopped.
        case idle
        /// Engine up but the device is on Wi-Fi, so the cellular profile is not in play.
        case notCellular
        /// On cellular, listener reachable, no proxied cellular traffic seen recently.
        case waiting
        /// Loopback traffic arrived over cellular at `Date`.
        case verified(Date)

        var isVerified: Bool {
            if case .verified = self { return true }
            return false
        }
    }

    @Published private(set) var state: State = .idle
    /// Result of the last TCP connect to the mixed inbound on loopback.
    @Published private(set) var listenerReachable: Bool?
    /// Live loopback connections on `mixed-in` at the last poll.
    @Published private(set) var loopbackConnections = 0
    @Published private(set) var lastCellularTraffic: Date?
    @Published private(set) var lastError: String?
    /// True while a manual `refresh()` probe is in flight (spins the refresh button).
    @Published private(set) var isRefreshing = false

    /// How long a verification stays green without new traffic.
    static let freshness: TimeInterval = 30
    private static let interval: Duration = .seconds(2)

    private static let connectionsRequest: URLRequest? = {
        guard let url = URL(string: "http://\(AppGroup.clashAPIAddress)/connections") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        return request
    }()

    private let path: NetworkPathObserver
    private var task: Task<Void, Never>?
    private var counters: [String: Int64] = [:]
    private var port = 0
    private var cancellables = Set<AnyCancellable>()

    private struct Snapshot: Decodable {
        var connections: [Connection]?
    }

    private struct Connection: Decodable {
        var id: String
        var metadata: Metadata
        var upload: Int64
        var download: Int64
    }

    private struct Metadata: Decodable {
        var type: String?
        var sourceIP: String?
    }

    init(path: NetworkPathObserver) {
        self.path = path
        // Flip between "On Wi-Fi" and "Awaiting cellular traffic" the moment the path changes
        // instead of waiting for the next two-second poll.
        path.$isCellular
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshState()
            }
            .store(in: &cancellables)
    }

    func start(port: Int) {
        self.port = port
        guard task == nil else { return }
        counters = [:]
        lastCellularTraffic = nil
        lastError = nil
        refreshState()
        task = Task { [weak self] in
            await self?.run()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        state = .idle
        listenerReachable = nil
        loopbackConnections = 0
    }

    /// One immediate listener probe + Clash API poll outside the two-second loop. No-op while the
    /// engine is stopped or a refresh is already running.
    func refresh() async {
        guard task != nil, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await poll()
    }

    // MARK: - Private

    private func run() async {
        while !Task.isCancelled {
            await poll()
            if Task.isCancelled { return }
            try? await Task.sleep(for: Self.interval)
        }
    }

    /// One verification pass: socket check, connection-table poll, state update.
    private func poll() async {
        // Socket check: a bare TCP connect that sends nothing, so it never shows up as traffic.
        let reachable = await LatencyTester.measure(host: AppSettings.localProxyHost, port: port, timeout: 2) != nil
        if Task.isCancelled { return }
        listenerReachable = reachable
        if let request = Self.connectionsRequest {
            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
                if Task.isCancelled { return }
                inspect(snapshot.connections ?? [], at: Date())
                lastError = nil
            } catch {
                if Task.isCancelled { return }
                lastError = error.localizedDescription
            }
        }
        refreshState()
    }

    /// Counts loopback connections on the primary inbound and notes when their bytes move while
    /// the device path is cellular.
    private func inspect(_ connections: [Connection], at now: Date) {
        var fresh: [String: Int64] = [:]
        var live = 0
        var moved = false
        for connection in connections {
            let source = connection.metadata.sourceIP ?? ""
            guard ConnectedClientsMonitor.isLoopback(source) else { continue }
            let inbound = connection.metadata.type ?? ""
            // The share listener is tagged share-in; everything else on mixed is the loopback inbound.
            guard !inbound.contains(SingBoxConfigBuilder.shareInboundTag) else { continue }
            live += 1
            let total = connection.upload + connection.download
            fresh[connection.id] = total
            if let before = counters[connection.id] {
                if total > before { moved = true }
            } else if total > 0 {
                moved = true
            }
        }
        counters = fresh
        loopbackConnections = live
        if moved, path.isCellular {
            lastCellularTraffic = now
        }
    }

    private func refreshState() {
        guard task != nil || state != .idle else { return }
        if let seen = lastCellularTraffic, Date().timeIntervalSince(seen) < Self.freshness, path.isCellular {
            state = .verified(seen)
        } else if path.isCellular {
            state = .waiting
        } else {
            state = .notCellular
        }
    }
}
