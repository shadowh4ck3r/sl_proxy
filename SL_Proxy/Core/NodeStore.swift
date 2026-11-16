import Combine
import Foundation
import UIKit

struct Subscription: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var url: String
    var lastUpdated: Date?
}

struct ImportResult {
    var added: Int
    var failures: [String]

    var summary: String {
        switch (added, failures.count) {
        case (0, 0): return "No proxy links found"
        case (0, _): return failures.first ?? "Import failed"
        case (_, 0): return added == 1 ? "1 server imported" : "\(added) servers imported"
        default: return "\(added) imported, \(failures.count) skipped"
        }
    }
}

enum NodeStoreError: LocalizedError {
    case noActiveNode
    case emptySubscription
    case badURL

    var errorDescription: String? {
        switch self {
        case .noActiveNode: return "Select a server in Configs first."
        case .emptySubscription: return "The subscription did not contain any supported servers."
        case .badURL: return "The subscription URL is not valid."
        }
    }
}

/// Owns imported servers and subscriptions, and generates the active sing-box config for the tunnel.
@MainActor
final class NodeStore: ObservableObject {
    @Published private(set) var nodes: [ProxyNode] = [] {
        didSet { persist(nodes, to: nodesFile) }
    }
    @Published private(set) var subscriptions: [Subscription] = [] {
        didSet { persist(subscriptions, to: subscriptionsFile) }
    }
    @Published var activeNodeID: UUID? {
        didSet { AppGroup.sharedDefaults.set(activeNodeID?.uuidString, forKey: activeKey) }
    }
    @Published private(set) var testingIDs: Set<UUID> = []
    @Published private(set) var refreshingIDs: Set<UUID> = []
    @Published private(set) var lastGeneratedConfig: String?
    @Published var toast: String?

    private let activeKey = "active-node-id"
    private let directory: URL
    private var nodesFile: URL { directory.appendingPathComponent("nodes.json") }
    private var subscriptionsFile: URL { directory.appendingPathComponent("subscriptions.json") }
    private var loading = true

    init() {
        let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        directory = AppGroup.containerURL ?? fallback
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        nodes = load([ProxyNode].self, from: nodesFile) ?? []
        subscriptions = load([Subscription].self, from: subscriptionsFile) ?? []
        if let stored = AppGroup.sharedDefaults.string(forKey: activeKey) {
            activeNodeID = UUID(uuidString: stored)
        }
        if activeNodeID == nil || !nodes.contains(where: { $0.id == activeNodeID }) {
            activeNodeID = nodes.first?.id
        }
        loading = false
    }

    // MARK: - Queries

    var activeNode: ProxyNode? { nodes.first { $0.id == activeNodeID } }
    var manualNodes: [ProxyNode] { nodes.filter { $0.subscriptionID == nil } }
    func nodes(in subscription: Subscription) -> [ProxyNode] { nodes.filter { $0.subscriptionID == subscription.id } }

    // MARK: - Import

    @discardableResult
    func importText(_ text: String) -> ImportResult {
        let parsed = ProxyURLParser.parseMany(text)
        nodes.append(contentsOf: parsed.nodes)
        if activeNodeID == nil { activeNodeID = parsed.nodes.first?.id }
        return ImportResult(added: parsed.nodes.count, failures: parsed.failures)
    }

    func importFromClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            toast = "Clipboard is empty"
            return
        }
        toast = importText(text).summary
    }

    /// Adds a hand-entered server and selects it when nothing else is selected.
    func add(_ node: ProxyNode) {
        nodes.append(node)
        if activeNodeID == nil { activeNodeID = node.id }
    }

    /// Adds (or refreshes) a purchased SailorsLoot proxy and returns the stored node. The
    /// username is unique per purchase, so it identifies the same purchase across launches.
    @discardableResult
    func addPurchased(_ purchase: SLPurchased, name: String) -> ProxyNode {
        if let index = nodes.firstIndex(where: { $0.kind == .socks && $0.username == purchase.username }) {
            nodes[index].expiresAt = purchase.expiresAt
            nodes[index].latencyMs = nil
            return nodes[index]
        }
        var node = ProxyNode(name: name, kind: .socks, server: purchase.host, port: purchase.port)
        node.username = purchase.username
        node.password = purchase.password
        node.expiresAt = purchase.expiresAt
        nodes.append(node)
        return node
    }

    /// Replaces a server in place. Returns true when the edited server is the active one.
    @discardableResult
    func update(_ node: ProxyNode) -> Bool {
        guard let index = nodes.firstIndex(where: { $0.id == node.id }) else { return false }
        nodes[index] = node
        return node.id == activeNodeID
    }

    func select(_ node: ProxyNode) {
        activeNodeID = node.id
    }

    func delete(_ node: ProxyNode) {
        nodes.removeAll { $0.id == node.id }
        if activeNodeID == node.id { activeNodeID = nodes.first?.id }
    }

    func deleteAll() {
        nodes.removeAll()
        subscriptions.removeAll()
        activeNodeID = nil
    }

    /// Replaces every server and subscription with a copy restored from iCloud Backup. The current
    /// selection is kept when the restored list still contains it, otherwise the first server wins.
    func restore(nodes restored: [ProxyNode], subscriptions restoredSubscriptions: [Subscription]) {
        nodes = restored
        subscriptions = restoredSubscriptions
        if activeNodeID == nil || !restored.contains(where: { $0.id == activeNodeID }) {
            activeNodeID = restored.first?.id
        }
    }

    // MARK: - Subscriptions

    func addSubscription(name: String, url: String) async {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: trimmed), parsed.scheme?.hasPrefix("http") == true else {
            toast = NodeStoreError.badURL.localizedDescription
            return
        }
        let subscription = Subscription(
            name: name.trimmingCharacters(in: .whitespaces).nonEmpty ?? (parsed.host ?? "Subscription"),
            url: trimmed
        )
        subscriptions.append(subscription)
        await refresh(subscription)
    }

    func refresh(_ subscription: Subscription) async {
        guard let url = URL(string: subscription.url) else { return }
        refreshingIDs.insert(subscription.id)
        defer { refreshingIDs.remove(subscription.id) }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("SL_Proxy/\(Bundle.main.shortVersion) sing-box", forHTTPHeaderField: "User-Agent")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let body = String(decoding: data, as: UTF8.self)
            let parsed = ProxyURLParser.parseMany(body)
            guard !parsed.nodes.isEmpty else { throw NodeStoreError.emptySubscription }

            let previousActiveName = activeNode?.subscriptionID == subscription.id ? activeNode?.name : nil
            var fresh = parsed.nodes
            for index in fresh.indices { fresh[index].subscriptionID = subscription.id }

            nodes.removeAll { $0.subscriptionID == subscription.id }
            nodes.append(contentsOf: fresh)
            if let index = subscriptions.firstIndex(where: { $0.id == subscription.id }) {
                subscriptions[index].lastUpdated = Date()
            }
            if let previousActiveName, let match = fresh.first(where: { $0.name == previousActiveName }) {
                activeNodeID = match.id
            } else if activeNodeID == nil || !nodes.contains(where: { $0.id == activeNodeID }) {
                activeNodeID = fresh.first?.id
            }
            toast = "\(subscription.name): \(fresh.count) servers"
        } catch {
            toast = "\(subscription.name): \(error.localizedDescription)"
        }
    }

    func refreshAll() async {
        for subscription in subscriptions {
            await refresh(subscription)
        }
    }

    func delete(_ subscription: Subscription) {
        nodes.removeAll { $0.subscriptionID == subscription.id }
        subscriptions.removeAll { $0.id == subscription.id }
        if activeNodeID == nil || !nodes.contains(where: { $0.id == activeNodeID }) {
            activeNodeID = nodes.first?.id
        }
    }

    // MARK: - Latency

    /// Latency shown next to a server; -1 means timeout / unreachable. For the active server while
    /// the core runs this is the real round trip of a URL test through the proxy outbound (what
    /// V2Box calls the real delay, the only number that proves the server forwards traffic). Every
    /// other server, and the active one while the core is stopped, gets the TCP connect time
    /// measured straight to the server, never through the carrier profile's APN proxy.
    func testLatency(_ node: ProxyNode) async {
        testingIDs.insert(node.id)
        let result = await Self.latency(of: node, isActive: node.id == activeNodeID)
        testingIDs.remove(node.id)
        if let index = nodes.firstIndex(where: { $0.id == node.id }) {
            nodes[index].latencyMs = result
        }
    }

    func testAll() async {
        let targets = nodes
        let activeID = activeNodeID
        testingIDs = Set(targets.map(\.id))
        await withTaskGroup(of: (UUID, Int).self) { group in
            for node in targets {
                group.addTask {
                    (node.id, await Self.latency(of: node, isActive: node.id == activeID))
                }
            }
            for await (id, result) in group {
                if let index = nodes.firstIndex(where: { $0.id == id }) {
                    nodes[index].latencyMs = result
                }
                testingIDs.remove(id)
            }
        }
        testingIDs.removeAll()
    }

    /// Smart Connect: tests every server and selects the fastest one that answered. Shows a toast
    /// with the result; nothing changes when no server answered.
    @discardableResult
    func smartConnect() async -> ProxyNode? {
        guard !nodes.isEmpty else { return nil }
        toast = "Smart Connect: testing \(nodes.count) servers..."
        await testAll()
        let answered = nodes.filter { ($0.latencyMs ?? -1) >= 0 }
        guard let best = answered.min(by: { ($0.latencyMs ?? Int.max) < ($1.latencyMs ?? Int.max) }) else {
            toast = "Smart Connect: no server answered"
            return nil
        }
        select(best)
        toast = "\u{1F406} Smart Connect: \(best.name) (\(best.latencyMs ?? 0) ms)"
        return best
    }

    /// Off the main actor: URL test through the core for the active node, TCP connect otherwise.
    /// A core that is not running falls through to the TCP probe; a server that does not answer
    /// either way is -1.
    nonisolated private static func latency(of node: ProxyNode, isActive: Bool) async -> Int {
        // An expired purchase is dead whatever its gateway still answers.
        if node.isExpired { return -1 }
        if isActive {
            switch await LatencyTester.realDelay() {
            case .delay(let ms): return ms
            case .unreachable: return -1
            case .unavailable: break
            }
        }
        // SOCKS5 / HTTP servers: do the real handshake with the credentials and fetch a URL through
        // the proxy. A plain TCP connect to a gateway still succeeds after the account or session
        // behind it has expired, which is how a dead server used to show a latency.
        if node.kind == .socks || node.kind == .http, !node.tls {
            return await LatencyTester.proxyRoundTrip(node: node) ?? -1
        }
        return await LatencyTester.measure(host: node.server, port: node.port) ?? -1
    }

    // MARK: - Active config

    /// Generates the sing-box config for the active node. The tunnel receives the returned JSON
    /// through the VPN profile; a copy is mirrored into the App Group container when one exists,
    /// but connecting never depends on it.
    @discardableResult
    func writeActiveConfig(settings: AppSettings) throws -> String {
        guard let node = activeNode else { throw NodeStoreError.noActiveNode }
        let json = try SingBoxConfigBuilder.build(node: node, settings: settings, allNodes: nodes)
        lastGeneratedConfig = json
        if let url = AppGroup.activeConfigURL {
            try? json.write(to: url, atomically: true, encoding: .utf8)
        }
        return json
    }

    /// Config preview without touching anything used by the tunnel.
    func previewConfig(settings: AppSettings) -> String? {
        guard let node = activeNode else { return nil }
        return try? SingBoxConfigBuilder.build(node: node, settings: settings, allNodes: nodes)
    }

    // MARK: - Persistence

    private func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func persist<T: Encodable>(_ value: T, to url: URL) {
        guard !loading, let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    var buildNumber: String { infoDictionary?["CFBundleVersion"] as? String ?? "0" }
}
