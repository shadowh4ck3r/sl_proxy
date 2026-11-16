import Combine
import Foundation
import UIKit

/// iCloud backup with auto sync and a list of the backups that exist.
///
/// Files live in the app's iCloud Drive container under `Documents/SL_Proxy Backups`:
///  - `SL_Proxy-auto-<device>.json`   one rolling file per device, rewritten by Auto Sync
///  - `SL_Proxy-<date>-<device>.json` manual "Back Up Now" snapshots (kept until you delete them)
///
/// Auto Sync: a few seconds after the server list or subscriptions change, the device's auto file is
/// rewritten. A fresh install with an empty Configs list restores the newest backup by itself.
/// Anything else is restored only when you tap a backup, so a sync can never wipe your list.
@MainActor
final class SLCloudSync: ObservableObject {
    static let shared = SLCloudSync()

    struct Backup: Identifiable, Hashable {
        let url: URL
        let device: String
        let date: Date
        let serverCount: Int
        let subscriptionCount: Int
        let isAuto: Bool
        var id: String { url.lastPathComponent }
    }

    private struct Payload: Codable {
        var version = 1
        var createdAt: Date
        var device: String
        var nodes: [ProxyNode]
        var subscriptions: [Subscription]
    }

    @Published private(set) var backups: [Backup] = []
    @Published private(set) var isAvailable = false
    @Published private(set) var isBusy = false
    @Published private(set) var lastSync: Date?
    @Published var message: String?
    @Published var autoSync: Bool {
        didSet {
            UserDefaults.standard.set(autoSync, forKey: Keys.autoSync)
            if autoSync { Task { await syncNow() } }
        }
    }

    private enum Keys {
        static let autoSync = "icloud.autoSync"
        static let lastSync = "icloud.lastSync"
    }

    private weak var store: NodeStore?
    private var container: URL?
    private var cancellable: AnyCancellable?

    private init() {
        autoSync = UserDefaults.standard.bool(forKey: Keys.autoSync)
        lastSync = UserDefaults.standard.object(forKey: Keys.lastSync) as? Date
    }

    // MARK: - Setup

    /// Call once at launch (`SLCloudSync.shared.attach(to: nodes)`). Safe when iCloud is unavailable.
    func attach(to nodes: NodeStore) {
        store = nodes
        cancellable = Publishers.CombineLatest(nodes.$nodes, nodes.$subscriptions)
            .dropFirst()
            .debounce(for: .seconds(5), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.autoSync else { return }
                Task { await self.syncNow() }
            }
        Task {
            await refresh()
            if autoSync, nodes.nodes.isEmpty, nodes.subscriptions.isEmpty,
               let newest = backups.first {
                restore(newest)
            }
        }
    }

    private func resolveContainer() async -> URL? {
        if let container { return container }
        let url: URL? = await Task.detached {
            FileManager.default.url(forUbiquityContainerIdentifier: nil)?
                .appendingPathComponent("Documents/SL_Proxy Backups", isDirectory: true)
        }.value
        guard let url else { return nil }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        container = url
        return url
    }

    // MARK: - Backups

    /// Reads the folder and lists every backup, newest first.
    func refresh() async {
        guard let folder = await resolveContainer() else {
            isAvailable = false
            backups = []
            return
        }
        isAvailable = true
        let found: [Backup] = await Task.detached { Self.scan(folder) }.value
        backups = found.sorted { $0.date > $1.date }
    }

    nonisolated private static func scan(_ folder: URL) -> [Backup] {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: folder.path)) ?? []
        var result: [Backup] = []
        for name in names {
            // Files that are still in iCloud only show up as ".name.json.icloud": ask for them now.
            if name.hasPrefix("."), name.hasSuffix(".icloud") {
                let real = String(name.dropFirst().dropLast(".icloud".count))
                try? manager.startDownloadingUbiquitousItem(at: folder.appendingPathComponent(real))
                continue
            }
            guard name.hasSuffix(".json") else { continue }
            let url = folder.appendingPathComponent(name)
            guard let payload = read(url) else { continue }
            result.append(Backup(url: url, device: payload.device, date: payload.createdAt,
                                 serverCount: payload.nodes.count, subscriptionCount: payload.subscriptions.count,
                                 isAuto: name.contains("-auto-")))
        }
        return result
    }

    nonisolated private static func read(_ url: URL) -> Payload? {
        var data: Data?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            data = try? Data(contentsOf: readable)
        }
        guard let data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Payload.self, from: data)
    }

    nonisolated private static func write(_ payload: Payload, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        var failure: Error?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { writable in
            do { try data.write(to: writable, options: .atomic) } catch { failure = error }
        }
        if let failure { throw failure }
        if let coordinationError { throw coordinationError }
    }

    // MARK: - Actions

    /// Auto Sync write: replaces this device's rolling file.
    func syncNow() async {
        await save(named: "SL_Proxy-auto-\(deviceTag).json", announce: false)
    }

    /// "Back Up Now": a separate dated snapshot.
    func backUpNow() async {
        let stamp = Self.fileStamp.string(from: Date())
        await save(named: "SL_Proxy-\(stamp)-\(deviceTag).json", announce: true)
    }

    private func save(named name: String, announce: Bool) async {
        guard let store, !isBusy else { return }
        guard let folder = await resolveContainer() else {
            isAvailable = false
            message = "iCloud is not available. Sign in to iCloud and turn on iCloud Drive."
            return
        }
        isBusy = true
        defer { isBusy = false }
        let payload = Payload(createdAt: Date(), device: UIDevice.current.name,
                              nodes: store.nodes, subscriptions: store.subscriptions)
        let target = folder.appendingPathComponent(name)
        do {
            try await Task.detached { try Self.write(payload, to: target) }.value
            lastSync = Date()
            UserDefaults.standard.set(lastSync, forKey: Keys.lastSync)
            if announce { message = "Backed up \(payload.nodes.count) servers to iCloud" }
            await refresh()
        } catch {
            message = "Backup failed: \(error.localizedDescription)"
        }
    }

    func restore(_ backup: Backup) {
        guard let store else { return }
        guard let payload = Self.read(backup.url) else {
            message = "Could not read that backup"
            return
        }
        store.restore(nodes: payload.nodes, subscriptions: payload.subscriptions)
        message = "Restored \(payload.nodes.count) servers"
    }

    func delete(_ backup: Backup) async {
        let url = backup.url
        await Task.detached {
            var error: NSError?
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &error) { try? FileManager.default.removeItem(at: $0) }
        }.value
        await refresh()
    }

    // MARK: - Naming

    private var deviceTag: String {
        let name = UIDevice.current.name.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
        let id = UIDevice.current.identifierForVendor?.uuidString.prefix(6) ?? "device"
        return String(name.prefix(18)) + "-" + id
    }

    private static let fileStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
