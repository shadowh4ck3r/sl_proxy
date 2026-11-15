import Foundation
import OSLog
#if canImport(Libbox)
import Libbox
#endif

// CI builds with REQUIRE_LIBBOX. Without this, an app that cannot see Libbox.xcframework compiles
// the core-less fallback below and ships a proxy that never proxies anything.
#if REQUIRE_LIBBOX && !canImport(Libbox)
#error("Libbox.xcframework is not visible to the SL_Proxy target; check Frameworks/Libbox.xcframework and FRAMEWORK_SEARCH_PATHS in project.yml")
#endif

/// Runs the sing-box core (Libbox) inside the app process: the user-space loopback engine.
///
/// The generated configuration has a single `mixed` inbound bound to `127.0.0.1` on the port chosen
/// in Settings (default 20080; 1080 is avoided because other proxy tools on the device usually hold
/// it and the bind fails with "address already in use"). sing-box accepts HTTP and SOCKS5
/// connections from other apps on this device and forwards them to the selected outbound. No TUN
/// device, no Network Extension, no NEVPNConnection and no App Group are involved, which is what
/// lets this variant run on iOS 17.x installs (TrollStore Lite, free Apple ID re-signs) where the
/// packet tunnel extension cannot launch.
///
/// `start(config:port:)` on a running engine closes the current core and starts a new one with the
/// new configuration; that is how a server switch, a routing change or a port change is applied.
final class LocalProxyEngine {
    /// Loopback only: the listener is never reachable from the LAN.
    static let listenAddress = AppSettings.localProxyHost
    /// Port used when the caller passes none. The live port always comes from Settings.
    static let defaultListenPort = AppSettings.defaultLocalProxyPort

    static func endpointDescription(port: Int) -> String { "\(listenAddress):\(port)" }

    /// True for the bind failure sing-box reports when another process already owns the port
    /// ("listen tcp 127.0.0.1:1080: bind: address already in use").
    static func isAddressInUse(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        return text.contains("address already in use") || text.contains("eaddrinuse")
    }

    let logs = EngineLogBuffer.shared

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? AppGroup.appBundleID, category: "engine")
    /// Every Libbox call happens on this serial queue; start() and close() can block for a while.
    private let queue = DispatchQueue(label: "com.slproxy.userspace.engine", qos: .userInitiated)

    // Snapshot state readable from any thread without waiting for the queue.
    private let stateLock = NSLock()
    private var _startedAt: Date?
    private var _lastError: String?
    private var _listenPort = AppSettings.defaultLocalProxyPort

    #if canImport(Libbox)
    // Queue-confined.
    private var service: LibboxBoxService?
    private var platform: AppPlatformInterface?
    private var coreReady = false
    #endif

    var startedAt: Date? { stateLock.withLock { _startedAt } }
    var lastError: String? { stateLock.withLock { _lastError } }
    var isRunning: Bool { startedAt != nil }
    /// Port the running core listens on (or the last one attempted).
    var listenPort: Int { stateLock.withLock { _listenPort } }
    /// `host:port` of the mixed inbound, e.g. `127.0.0.1:20080`.
    var endpointDescription: String { Self.endpointDescription(port: listenPort) }

    // MARK: - Control

    /// Starts sing-box with `config`, whose mixed inbound listens on `port`, replacing a running
    /// instance. Returns once the inbound listens. A busy port surfaces as an error that
    /// `isAddressInUse` recognises so the caller can retry with an alternative.
    func start(config: String, port: Int = LocalProxyEngine.defaultListenPort) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.startOnQueue(config: config, port: port)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.stopOnQueue(reason: "stopped from the app")
                continuation.resume()
            }
        }
    }

    /// Writes to the unified log and to the buffer shown in the Logs tab. Safe from any thread.
    func record(_ message: String) {
        log.info("\(message, privacy: .public)")
        logs.append(message)
    }

    // MARK: - Queue-confined

    private func startOnQueue(config: String, port: Int) throws {
        setLastError(nil)
        stateLock.withLock { _listenPort = port }
        let endpoint = Self.endpointDescription(port: port)
        if isRunning {
            record("Configuration changed: restarting sing-box (mixed inbound on \(endpoint))")
            stopOnQueue(reason: "configuration changed")
        } else {
            record("Starting sing-box in user-space mode (mixed inbound on \(endpoint))")
        }

        #if canImport(Libbox)
        do {
            try setupCoreIfNeeded()
            let platform = AppPlatformInterface(engine: self)
            var creationError: NSError?
            guard let service = LibboxNewService(config, platform, &creationError) else {
                throw creationError ?? EngineError.coreUnavailable
            }
            try service.start()
            self.platform = platform
            self.service = service
            setStartedAt(Date())
            record("sing-box core started; HTTP + SOCKS5 proxy listening on \(endpoint)")
        } catch {
            platform?.reset()
            platform = nil
            service = nil
            throw startFailure(error)
        }
        #else
        throw startFailure(EngineError.notLinked)
        #endif
    }

    private func stopOnQueue(reason: String) {
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
        if isRunning {
            record("sing-box core stopped (\(reason))")
        }
        setStartedAt(nil)
    }

    #if canImport(Libbox)
    private func setupCoreIfNeeded() throws {
        guard !coreReady else { return }
        let fm = FileManager.default
        let root = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        let base = root.appendingPathComponent("SL_Proxy", isDirectory: true)
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
            throw setupError ?? EngineError.coreUnavailable
        }
        // The app process has no 50 MB Network Extension limit, so the memory limiter stays off.
        coreReady = true
    }
    #endif

    /// Records the failure and returns an error whose description carries the last log lines, so
    /// the Home screen shows what the core complained about (port in use, bad outbound, ...).
    private func startFailure(_ error: Error) -> NSError {
        setLastError(error.localizedDescription)
        record("Error: \(error.localizedDescription)")
        let tail = logs.tail(8).joined(separator: "\n")
        return NSError(
            domain: Bundle.main.bundleIdentifier ?? AppGroup.appBundleID,
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "\(error.localizedDescription)\n\nEngine log:\n\(tail)"]
        )
    }

    private func setStartedAt(_ date: Date?) {
        stateLock.withLock { _startedAt = date }
    }

    private func setLastError(_ message: String?) {
        stateLock.withLock { _lastError = message }
    }

    enum EngineError: LocalizedError {
        case notLinked
        case coreUnavailable

        var errorDescription: String? {
            switch self {
            case .notLinked:
                return "This build does not contain the sing-box core (Libbox.xcframework was not linked)."
            case .coreUnavailable:
                return "The sing-box core failed to initialise."
            }
        }
    }
}
