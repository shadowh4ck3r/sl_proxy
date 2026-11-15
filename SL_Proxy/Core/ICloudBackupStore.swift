import Combine
import Foundation
import UIKit

/// Data covered by iCloud Backup. Compared to decide whether a push is needed, so it excludes
/// anything that changes without the user editing it (latency results, selection).
struct BackupContent: Codable, Equatable {
    var nodes: [ProxyNode]
    var subscriptions: [Subscription]
    var settings: AppSettings
}

/// One backup as stored under `ICloudBackupStore.snapshotKey`.
struct BackupSnapshot: Codable, Equatable {
    static let currentVersion = 1

    var version = BackupSnapshot.currentVersion
    var savedAt: Date
    var deviceName: String
    var content: BackupContent
}

enum ICloudBackupStatus: Equatable {
    case connecting
    case syncing
    case synced(Date)
    case error(String)

    var isError: Bool {
        if case .error = self { return true }
        return false
    }

    var systemImage: String {
        switch self {
        case .connecting: return "icloud"
        case .syncing: return "arrow.triangle.2.circlepath.icloud"
        case .synced: return "checkmark.icloud.fill"
        case .error: return "exclamationmark.icloud.fill"
        }
    }
}

/// Mirrors servers, subscriptions, rules and application options into the user's iCloud account
/// through `NSUbiquitousKeyValueStore` (Settings > Advanced & Pro > iCloud Backup).
///
/// The initializer connects to the default key-value store, registers the listeners and starts the
/// first sync. Afterwards every local change observed on `NodeStore` and `SettingsStore` is
/// debounced and uploaded as one JSON snapshot; snapshots written by another device arrive through
/// `didChangeExternallyNotification` and are applied when they are newer than the last local sync
/// (last writer wins, which is the key-value store's own model).
///
/// Requirements the store reports through `status` instead of failing silently:
/// - an iCloud account on the device (`FileManager.ubiquityIdentityToken`),
/// - the `com.apple.developer.ubiquity-kvstore-identifier` entitlement (`synchronize()` returns
///   false without it, which is the case for unsigned or re-signed IPAs),
/// - the 1 MB per-app quota of the key-value store.
@MainActor
final class ICloudBackupStore: ObservableObject {
    @Published private(set) var status: ICloudBackupStatus = .connecting
    @Published private(set) var lastSynced: Date?
    /// Name of the device that wrote the snapshot currently in iCloud, when known.
    @Published private(set) var lastRemoteDevice: String?
    /// Encoded size of the last snapshot pushed or received.
    @Published private(set) var payloadBytes = 0
    /// Ticks every 30 s so the relative "Synced ..." label stays current.
    @Published private var now = Date()

    static let snapshotKey = "sl-proxy.backup.snapshot"
    static let savedAtKey = "sl-proxy.backup.saved-at"
    /// NSUbiquitousKeyValueStore allows 1 MB per app (and per key).
    static let maxPayloadBytes = 1_000_000

    private static let lastSyncedKey = "icloud-backup-last-synced"
    private static let pushDelay: Duration = .seconds(1.5)

    private let store: NSUbiquitousKeyValueStore
    private let nodes: NodeStore
    private let settings: SettingsStore
    private var cancellables: Set<AnyCancellable> = []
    private var pushTask: Task<Void, Never>?
    private var lastSyncedContent: BackupContent?

    init(nodes: NodeStore, settings: SettingsStore, store: NSUbiquitousKeyValueStore = .default) {
        self.nodes = nodes
        self.settings = settings
        self.store = store
        if let stamp = AppGroup.sharedDefaults.object(forKey: Self.lastSyncedKey) as? Double {
            lastSynced = Date(timeIntervalSince1970: stamp)
        }

        let center = NotificationCenter.default

        // Snapshots written by another device, the initial download after sign-in, account
        // switches and quota violations all arrive here.
        center.publisher(for: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store)
            .sink { [weak self] note in
                let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
                let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
                Task { @MainActor in self?.handleExternalChange(reason: reason, keys: keys) }
            }
            .store(in: &cancellables)

        // iCloud account signed in, out or switched.
        center.publisher(for: .NSUbiquityIdentityDidChange)
            .sink { [weak self] _ in Task { @MainActor in self?.start() } }
            .store(in: &cancellables)

        // Re-check the account and pull whatever arrived while the app was suspended.
        center.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.start() } }
            .store(in: &cancellables)

        // Local edits: custom servers, subscriptions, rules and every application option.
        nodes.$nodes
            .sink { [weak self] _ in Task { @MainActor in self?.noteLocalChange() } }
            .store(in: &cancellables)
        nodes.$subscriptions
            .sink { [weak self] _ in Task { @MainActor in self?.noteLocalChange() } }
            .store(in: &cancellables)
        settings.$value
            .sink { [weak self] _ in Task { @MainActor in self?.noteLocalChange() } }
            .store(in: &cancellables)

        Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] date in Task { @MainActor in self?.now = date } }
            .store(in: &cancellables)

        start()
    }

    // MARK: - Status

    /// Label shown on the iCloud Backup screen.
    var statusText: String {
        switch status {
        case .connecting:
            return "Connecting to iCloud…"
        case .syncing:
            return "Connected to iCloud: Syncing…"
        case .synced(let date):
            return "Connected to iCloud: Synced \(Self.relative(date, to: now))"
        case .error(let message):
            return "iCloud sync error: \(message)"
        }
    }

    private static func relative(_ date: Date, to now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return "Just Now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    private static let noAccountMessage =
        "No iCloud account is signed in on this device. Sign in under Settings > Apple Account and turn on iCloud Drive."
    private static let notEntitledMessage =
        "This build cannot open the iCloud key-value container (missing ubiquity-kvstore entitlement). Re-sign the IPA with iCloud enabled."
    private static let quotaMessage =
        "The iCloud key-value quota (1 MB) is exceeded. Remove unused servers or subscriptions and back up again."

    // MARK: - Lifecycle

    /// Checks the account, pulls the latest remote snapshot and pushes the local data. Runs on
    /// init, when the app returns to the foreground and whenever the iCloud identity changes.
    func start() {
        guard FileManager.default.ubiquityIdentityToken != nil else {
            status = .error(Self.noAccountMessage)
            return
        }
        status = .syncing
        guard store.synchronize() else {
            status = .error(Self.notEntitledMessage)
            return
        }

        let local = currentContent
        if let remote = readRemote() {
            if remote.content == local {
                lastSyncedContent = remote.content
                lastRemoteDevice = remote.deviceName
                markSynced(remote.savedAt)
                return
            }
            // Another device wrote after this one last synced (or this is a fresh install):
            // adopt the cloud copy. Otherwise the local copy is newer and is pushed below.
            if remote.savedAt > (lastSynced ?? .distantPast) {
                apply(remote)
                return
            }
        }
        push(force: true)
    }

    /// Manual push from the iCloud Backup screen.
    func backUpNow() {
        pushTask?.cancel()
        push(force: true)
    }

    // MARK: - Local changes

    private func noteLocalChange() {
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.pushDelay)
            guard !Task.isCancelled else { return }
            self?.push()
        }
    }

    private var currentContent: BackupContent {
        // Latency results change on every test and are meaningless on another device.
        var stripped = nodes.nodes
        for index in stripped.indices { stripped[index].latencyMs = nil }
        return BackupContent(nodes: stripped, subscriptions: nodes.subscriptions, settings: settings.value)
    }

    private func push(force: Bool = false) {
        guard FileManager.default.ubiquityIdentityToken != nil else {
            status = .error(Self.noAccountMessage)
            return
        }
        let content = currentContent
        if !force, content == lastSyncedContent { return }

        status = .syncing
        let snapshot = BackupSnapshot(savedAt: Date(), deviceName: UIDevice.current.name, content: content)
        let data: Data
        do {
            data = try JSONEncoder().encode(snapshot)
        } catch {
            status = .error("The backup could not be encoded: \(error.localizedDescription)")
            return
        }
        guard data.count <= Self.maxPayloadBytes else {
            let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
            status = .error("The backup is \(size), above the 1 MB iCloud key-value limit. Remove unused servers or subscriptions.")
            return
        }

        store.set(data, forKey: Self.snapshotKey)
        store.set(snapshot.savedAt.timeIntervalSince1970, forKey: Self.savedAtKey)
        guard store.synchronize() else {
            status = .error(Self.notEntitledMessage)
            return
        }
        payloadBytes = data.count
        lastSyncedContent = content
        lastRemoteDevice = snapshot.deviceName
        markSynced(snapshot.savedAt)
    }

    // MARK: - Remote changes

    private func handleExternalChange(reason: Int?, keys: [String]) {
        switch reason {
        case NSUbiquitousKeyValueStoreQuotaViolationChange:
            status = .error(Self.quotaMessage)
        case NSUbiquitousKeyValueStoreAccountChange:
            start()
        default:
            // Server change or initial sync: apply the snapshot when it is newer than ours.
            guard keys.contains(Self.snapshotKey), let remote = readRemote() else { return }
            if remote.content == currentContent {
                lastSyncedContent = remote.content
                lastRemoteDevice = remote.deviceName
                markSynced(remote.savedAt)
            } else if remote.savedAt > (lastSynced ?? .distantPast) {
                apply(remote)
            }
        }
    }

    private func readRemote() -> BackupSnapshot? {
        guard let data = store.data(forKey: Self.snapshotKey),
              let snapshot = try? JSONDecoder().decode(BackupSnapshot.self, from: data) else {
            return nil
        }
        payloadBytes = data.count
        return snapshot
    }

    /// Replaces the local servers, subscriptions and options with the cloud copy. The observers
    /// fire, but `lastSyncedContent` already matches so no push follows.
    private func apply(_ remote: BackupSnapshot) {
        pushTask?.cancel()
        lastSyncedContent = remote.content
        nodes.restore(nodes: remote.content.nodes, subscriptions: remote.content.subscriptions)
        if settings.value != remote.content.settings {
            settings.value = remote.content.settings
        }
        lastRemoteDevice = remote.deviceName
        markSynced(remote.savedAt)
    }

    private func markSynced(_ date: Date) {
        lastSynced = date
        now = Date()
        status = .synced(date)
        AppGroup.sharedDefaults.set(date.timeIntervalSince1970, forKey: Self.lastSyncedKey)
    }
}
