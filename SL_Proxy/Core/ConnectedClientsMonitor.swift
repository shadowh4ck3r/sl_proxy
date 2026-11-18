import Combine
import Foundation

/// One remote device using the Proxy Share listener, grouped by source IP from the sing-box Clash
/// API `/connections` snapshot.
struct ConnectedClient: Identifiable, Equatable {
    let ip: String
    /// Inbound the device arrived through, e.g. `mixed/share-in`.
    var inbound: String
    /// Live connections right now; 0 for a device that has gone idle.
    var connections: Int
    var downloadSpeed: Int64
    var uploadSpeed: Int64
    /// Bytes moved for this device since sharing started.
    var downloadTotal: Int64
    var uploadTotal: Int64
    var lastSeen: Date
    /// Most recent destinations, newest first (at most `ConnectedClientsMonitor.maxHosts`).
    var recentHosts: [String]

    var id: String { ip }
    var isActive: Bool { connections > 0 }
}

/// Lists the devices using the Proxy Share listener with their live bandwidth.
///
/// Polls the sing-box Clash API `GET /connections` snapshot (`AppGroup.clashAPIAddress`) once a
/// second, drops connections that arrived over loopback (apps on this device), and groups the rest
/// by `metadata.sourceIP`. Speeds are the byte deltas of each connection between two polls, so a
/// connection that opens and closes within one second is not counted; totals accumulate per IP
/// for the session. `TunnelController` starts it together with the share listener.
@MainActor
final class ConnectedClientsMonitor: ObservableObject {
    @Published private(set) var clients: [ConnectedClient] = []
    @Published private(set) var isPolling = false
    @Published private(set) var lastError: String?

    static let maxHosts = 3
    /// Idle devices leave the list this long after their last connection closed.
    static let retention: TimeInterval = 120
    private static let interval: Duration = .seconds(1)

    private var task: Task<Void, Never>?
    /// Byte counters per connection id from the previous snapshot; deltas feed the per-IP speeds.
    private var counters: [String: Counter] = [:]
    /// Accumulated bytes per IP for the current session.
    private var totals: [String: Counter] = [:]
    private var lastSeen: [String: Date] = [:]
    private var inbounds: [String: String] = [:]
    private var hosts: [String: [String]] = [:]
    private var lastTick: Date?

    private struct Counter: Equatable {
        var up: Int64 = 0
        var down: Int64 = 0
    }

    // Clash API shape written by sing-box's TrackerMetadata.MarshalJSON.
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
        var destinationIP: String?
        var host: String?
    }

    var activeCount: Int { clients.filter(\.isActive).count }
    var totalDownloadSpeed: Int64 { clients.reduce(0) { $0 + $1.downloadSpeed } }
    var totalUploadSpeed: Int64 { clients.reduce(0) { $0 + $1.uploadSpeed } }

    func start() {
        guard task == nil else { return }
        reset()
        isPolling = true
        task = Task { [weak self] in
            await self?.poll()
        }
    }

    /// Stops polling. Speeds drop to zero; session totals stay visible until the next `start()`.
    func stop() {
        task?.cancel()
        task = nil
        isPolling = false
        clients = clients.map { client in
            var idle = client
            idle.connections = 0
            idle.downloadSpeed = 0
            idle.uploadSpeed = 0
            return idle
        }
    }

    func reset() {
        counters = [:]
        totals = [:]
        lastSeen = [:]
        inbounds = [:]
        hosts = [:]
        lastTick = nil
        clients = []
        lastError = nil
    }

    /// True for connections made by apps on this device through the loopback listener.
    static func isLoopback(_ ip: String) -> Bool {
        ip.isEmpty || ip.hasPrefix("127.") || ip == "::1" || ip.hasPrefix("::ffff:127.")
    }

    // MARK: - Private

    private func poll() async {
        guard let url = URL(string: "http://\(AppGroup.clashAPIAddress)/connections") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        while !Task.isCancelled {
            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
                if Task.isCancelled { return }
                apply(snapshot.connections ?? [], at: Date())
                lastError = nil
            } catch {
                if Task.isCancelled { return }
                lastError = error.localizedDescription
            }
            try? await Task.sleep(for: Self.interval * ThermalGuard.pollScale)
        }
    }

    private func apply(_ connections: [Connection], at now: Date) {
        let elapsed = lastTick.map { max(now.timeIntervalSince($0), 0.001) } ?? 0
        lastTick = now

        var live: [String: Int] = [:]
        var deltas: [String: Counter] = [:]
        var fresh: [String: Counter] = [:]

        for connection in connections {
            let ip = connection.metadata.sourceIP ?? ""
            guard !Self.isLoopback(ip) else { continue }
            let current = Counter(up: connection.upload, down: connection.download)
            fresh[connection.id] = current
            let before = counters[connection.id] ?? Counter()
            var delta = deltas[ip] ?? Counter()
            delta.up += max(current.up - before.up, 0)
            delta.down += max(current.down - before.down, 0)
            deltas[ip] = delta
            live[ip, default: 0] += 1
            lastSeen[ip] = now
            if let inbound = connection.metadata.type?.nonEmpty { inbounds[ip] = inbound }
            if let host = connection.metadata.host?.nonEmpty ?? connection.metadata.destinationIP?.nonEmpty {
                var list = hosts[ip] ?? []
                list.removeAll { $0 == host }
                list.insert(host, at: 0)
                if list.count > Self.maxHosts { list.removeLast(list.count - Self.maxHosts) }
                hosts[ip] = list
            }
        }
        counters = fresh

        for (ip, delta) in deltas {
            var total = totals[ip] ?? Counter()
            total.up += delta.up
            total.down += delta.down
            totals[ip] = total
        }

        // Devices idle for longer than the retention window drop off the list.
        for (ip, seen) in lastSeen where live[ip] == nil && now.timeIntervalSince(seen) > Self.retention {
            lastSeen[ip] = nil
            totals[ip] = nil
            inbounds[ip] = nil
            hosts[ip] = nil
        }

        clients = lastSeen.keys.map { ip in
            let delta = deltas[ip] ?? Counter()
            let total = totals[ip] ?? Counter()
            return ConnectedClient(
                ip: ip,
                inbound: inbounds[ip] ?? "",
                connections: live[ip] ?? 0,
                downloadSpeed: elapsed > 0 ? Int64(Double(delta.down) / elapsed) : 0,
                uploadSpeed: elapsed > 0 ? Int64(Double(delta.up) / elapsed) : 0,
                downloadTotal: total.down,
                uploadTotal: total.up,
                lastSeen: lastSeen[ip] ?? now,
                recentHosts: hosts[ip] ?? []
            )
        }
        .sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            let left = lhs.downloadSpeed + lhs.uploadSpeed
            let right = rhs.downloadSpeed + rhs.uploadSpeed
            if left != right { return left > right }
            return lhs.ip < rhs.ip
        }
    }
}
