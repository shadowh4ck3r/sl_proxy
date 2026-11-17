import Combine
import CryptoKit
import Foundation
import JavaScriptCore
import UIKit

// MARK: - Bundle model (ui.json)

/// Arbitrary JSON, used for the `args` of a `js` action.
enum OTAJSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([OTAJSONValue])
    case object([String: OTAJSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([OTAJSONValue].self) { self = .array(v) }
        else if let v = try? c.decode([String: OTAJSONValue].self) { self = .object(v) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value") }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    /// Plain Foundation value for JavaScriptCore.
    var foundation: Any {
        switch self {
        case .string(let v): return v
        case .number(let v): return v
        case .bool(let v): return v
        case .null: return NSNull()
        case .array(let v): return v.map(\.foundation)
        case .object(let v): return v.mapValues(\.foundation)
        }
    }
}

/// What a tap does. `js` calls a function of `logic.js`; the others are handled natively.
struct OTAAction: Codable, Equatable {
    /// `js`, `url`, `toast` or `dismiss`.
    var type: String
    var fn: String?
    var args: [OTAJSONValue]?
    var url: String?
    var message: String?
}

/// One server-driven element. Unknown `type` values are ignored, so a newer `ui.json` never breaks
/// an older app.
struct OTAComponent: Codable, Identifiable, Equatable {
    var id: String
    /// `banner`, `card`, `button`, `toggle` or `modal`.
    var type: String
    /// `home.top`, `home.bottom` or `settings.top`. Default `home.top`.
    var placement: String?
    var title: String?
    var body: String?
    /// SF Symbol name.
    var icon: String?
    var imageURL: String?
    var buttonTitle: String?
    /// Flag name a `toggle` reads and writes.
    var key: String?
    var action: OTAAction?
    /// Modals only: show once per `id` (default true).
    var showOnce: Bool?
    var dismissible: Bool?
    /// ISO 8601 window.
    var startsAt: String?
    var expiresAt: String?
    var minAppVersion: String?
    var enabled: Bool?
}

struct OTAUI: Codable, Equatable {
    var schema: Int
    /// Default values for feature flags; the user's own toggles win.
    var flags: [String: Bool]?
    var components: [OTAComponent]
}

// MARK: - Thread-safe helpers

/// Feature flags, readable from the JavaScript queue and the main thread.
final class OTAFlagStore {
    private let lock = NSLock()
    private var values: [String: Bool]
    private let defaultsKey = "ota.flags"
    private let persistent: Bool
    private static let maxFlags = 200

    /// `persistent: false` keeps everything in memory (validation runs must not touch real flags).
    init(persistent: Bool = true) {
        self.persistent = persistent
        values = persistent ? ((UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Bool]) ?? [:]) : [:]
    }

    func get(_ key: String) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    @discardableResult
    func set(_ key: String, _ value: Bool) -> Bool {
        guard !key.isEmpty, key.count <= 64 else { return false }
        lock.lock()
        guard values[key] != nil || values.count < Self.maxFlags else { lock.unlock(); return false }
        values[key] = value
        let copy = values
        lock.unlock()
        if persistent { UserDefaults.standard.set(copy, forKey: defaultsKey) }
        return true
    }
}

/// Latest `getAppState()` answer, written on the main thread and read on the JavaScript queue.
final class OTAStateBox {
    private let lock = NSLock()
    private var state: [String: Any] = [:]
    var value: [String: Any] {
        get { lock.lock(); defer { lock.unlock() }; return state }
        set { lock.lock(); state = newValue; lock.unlock() }
    }
}

/// Resumes a continuation exactly once, whichever of "finished" and "timed out" comes first.
private final class OnceGate {
    private let lock = NSLock()
    private var used = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}

// MARK: - JavaScript runtime

/// What `logic.js` may ask the app to do. Every closure is safe to call from the JavaScript queue.
struct OTABridge {
    var toast: @Sendable (String) -> Void
    var applyProxyConfig: @Sendable (String) -> Bool
    var setRoutingMode: @Sendable (String) -> Bool
    var openURL: @Sendable (String) -> Bool
    var appState: @Sendable () -> [String: Any]
    var flags: OTAFlagStore
    var log: @Sendable (String) -> Void

    /// No-op bridge for validation: top-level code may call the functions, nothing happens.
    static let inert = OTABridge(
        toast: { _ in }, applyProxyConfig: { _ in false }, setRoutingMode: { _ in false },
        openURL: { _ in false }, appState: { [:] }, flags: OTAFlagStore(persistent: false), log: { _ in }
    )
}

struct OTACallResult {
    var value: Any?
    var error: String?
    var timedOut = false
}

/// One sandboxed `JSContext` on its own serial queue. There is no file, network or timer API in the
/// context; the only way out is the bridge above. JavaScriptCore cannot interrupt a running script,
/// so a script that never returns only blocks this queue: callers time out after a few seconds, mark
/// the runtime as stuck and the manager replaces it. The main thread is never blocked.
final class OTAJSRuntime {
    private let queue = DispatchQueue(label: "com.slproxy.ota.js", qos: .userInitiated)
    private var context: JSContext?
    private var lastException: String?
    private(set) var isStuck = false

    private func run<T>(timeout: TimeInterval, fallback: T, _ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            let gate = OnceGate()
            queue.async {
                let result = work()
                if gate.claim() { continuation.resume(returning: result) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if gate.claim() {
                    self.isStuck = true
                    continuation.resume(returning: fallback)
                }
            }
        }
    }

    /// Evaluates `logic` in a fresh context. Returns an error text, or nil when it loaded cleanly.
    func load(logic: String, bridge: OTABridge, timeout: TimeInterval = 3) async -> String? {
        await run(timeout: timeout, fallback: "logic.js did not finish loading within \(Int(timeout)) s") {
            guard let context = JSContext() else { return "JavaScriptCore is unavailable" }
            context.exceptionHandler = { [weak self] _, exception in
                self?.lastException = exception?.toString() ?? "unknown JavaScript error"
            }
            Self.install(bridge, in: context)
            self.context = context
            self.lastException = nil
            context.evaluateScript(logic)
            if let error = self.lastException {
                self.context = nil
                return "logic.js: \(error)"
            }
            return nil
        }
    }

    /// Names from `names` that are not functions in the loaded script.
    func missingFunctions(_ names: [String]) async -> [String] {
        await run(timeout: 2, fallback: names) {
            guard let context = self.context,
                  let isFunction = context.evaluateScript("(function (f) { return typeof f === 'function'; })")
            else { return names }
            return names.filter { name in
                guard Self.isValidIdentifier(name) else { return true }
                let value = context.objectForKeyedSubscript(name)
                return isFunction.call(withArguments: [value as Any])?.toBool() != true
            }
        }
    }

    func call(_ function: String, args: [Any], timeout: TimeInterval = 3) async -> OTACallResult {
        let timedOut = OTACallResult(value: nil, error: "\(function) took longer than \(Int(timeout)) s", timedOut: true)
        return await run(timeout: timeout, fallback: timedOut) {
            guard Self.isValidIdentifier(function), let context = self.context else {
                return OTACallResult(value: nil, error: "\(function) is not available")
            }
            let target = context.objectForKeyedSubscript(function)
            guard let target, target.isObject else {
                return OTACallResult(value: nil, error: "\(function) is not defined")
            }
            self.lastException = nil
            let value = target.call(withArguments: args)
            if let error = self.lastException { return OTACallResult(value: nil, error: "\(function): \(error)") }
            guard let value, !value.isUndefined, !value.isNull else { return OTACallResult(value: nil, error: nil) }
            return OTACallResult(value: value.toObject(), error: nil)
        }
    }

    func hasFunction(_ name: String) async -> Bool {
        await missingFunctions([name]).isEmpty
    }

    static func isValidIdentifier(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.count <= 64 else { return false }
        let head = CharacterSet.letters.union(CharacterSet(charactersIn: "_$"))
        let tail = head.union(.decimalDigits)
        return head.contains(first) && name.unicodeScalars.allSatisfy { tail.contains($0) }
    }

    // MARK: Bridge installation

    private static func install(_ bridge: OTABridge, in context: JSContext) {
        func expose(_ name: String, _ block: AnyObject) {
            context.setObject(block, forKeyedSubscript: name as NSString)
        }

        let setToast: @convention(block) (String) -> Void = { message in
            bridge.toast(String(message.prefix(300)))
        }
        expose("setToast", unsafeBitCast(setToast, to: AnyObject.self))

        let applyProxyConfig: @convention(block) (String) -> Bool = { config in
            bridge.applyProxyConfig(config)
        }
        expose("applyProxyConfig", unsafeBitCast(applyProxyConfig, to: AnyObject.self))

        let setRoutingMode: @convention(block) (String) -> Bool = { mode in
            bridge.setRoutingMode(mode)
        }
        expose("setRoutingMode", unsafeBitCast(setRoutingMode, to: AnyObject.self))

        let getAppState: @convention(block) () -> [String: Any] = {
            bridge.appState()
        }
        expose("getAppState", unsafeBitCast(getAppState, to: AnyObject.self))

        let openURL: @convention(block) (String) -> Bool = { url in
            bridge.openURL(url)
        }
        expose("openURL", unsafeBitCast(openURL, to: AnyObject.self))

        let getFlag: @convention(block) (String, Bool) -> Bool = { key, fallback in
            bridge.flags.get(key) ?? fallback
        }
        expose("getFlag", unsafeBitCast(getFlag, to: AnyObject.self))

        let setFlag: @convention(block) (String, Bool) -> Bool = { key, value in
            bridge.flags.set(key, value)
        }
        expose("setFlag", unsafeBitCast(setFlag, to: AnyObject.self))

        let log: @convention(block) (String) -> Void = { message in
            bridge.log(String(message.prefix(500)))
        }
        if let console = context.evaluateScript("({})") {
            console.setObject(unsafeBitCast(log, to: AnyObject.self), forKeyedSubscript: "log" as NSString)
            context.setObject(console, forKeyedSubscript: "console" as NSString)
        }
        expose("log", unsafeBitCast(log, to: AnyObject.self))
    }
}

// MARK: - Manager

/// Over-the-air UI and logic from the WordPress site.
///
/// 1. On launch and every time the app becomes active, `checkForUpdates()` downloads the current
///    bundle (`ui.json` + `logic.js`) from `primaryURL`, or from `backupURL` when the primary fails
///    or does not answer within 5 seconds. Every request is uncached and carries `?t=<timestamp>`.
/// 2. The download is validated before it is used: `ui.json` must decode, `logic.js` must load in a
///    sandboxed `JSContext` without an exception, every function the UI calls must exist and, when a
///    public key is configured, the Ed25519 signature must match. Only then is it written to
///    Documents/OTA and UserDefaults. A failed check, or an unreachable site, silently keeps what
///    is already running.
/// 3. With nothing cached (first offline launch) the starter bundle inside the app is used
///    (`default_ui.json`, `default_logic.js`); with nothing valid at all the native UI shows alone.
///
/// `logic.js` talks to the app through `setToast`, `applyProxyConfig`, `getAppState` and a few more
/// (see `OTAJSRuntime.install`). Nothing here executes native code from the server.
@MainActor
final class OTAManager: ObservableObject {
    struct Configuration {
        var primaryURL: String
        /// Optional. Skipped when nil or empty; the server can also supply one (`backup_url`).
        var backupURL: String? = nil
        /// Base64 raw Ed25519 public key. When set, every downloaded bundle must carry a valid
        /// signature; when nil or empty, signatures are not checked.
        var publicKeyBase64: String? = nil
        var primaryTimeout: TimeInterval = 5
        var backupTimeout: TimeInterval = 8
        /// Checks closer together than this are skipped (launch + didBecomeActive fire back to back).
        var minimumCheckInterval: TimeInterval = 20

        static let live = Configuration(primaryURL: "https://sailorsloot.xyz/wp-json/slproxy/v1/ota")
    }

    enum Source: String {
        case none, bundled, cached, remote
    }

    /// Highest `ui.json` schema this app understands.
    static let supportedSchema = 1
    private static let maxBundleBytes = 512 * 1024

    @Published private(set) var ui: OTAUI?
    @Published private(set) var version = "none"
    @Published private(set) var source: Source = .none
    @Published private(set) var lastChecked: Date?
    @Published private(set) var lastError: String?
    /// Bumped whenever a flag changes, so views that read `flag(_:)` refresh.
    @Published private(set) var flagRevision = 0
    @Published var pendingModal: OTAComponent?

    private let configuration: Configuration
    private let flagStore = OTAFlagStore()
    private let defaults = UserDefaults.standard
    private var runtime = OTAJSRuntime()
    private var runtimeReady = false
    private var logicText = ""

    private weak var nodes: NodeStore?
    private weak var settings: SettingsStore?
    private weak var tunnel: TunnelController?

    private var started = false
    private var isChecking = false
    private var lastAttempt: Date?
    private var cancellables = Set<AnyCancellable>()
    private let stateBox = OTAStateBox()

    private enum Key {
        static let version = "ota.version"
        static let ui = "ota.ui"
        static let logic = "ota.logic"
        static let backupURL = "ota.backupURL"
        static let dismissed = "ota.dismissed"
        static let seenModals = "ota.seenModals"
    }

    init(configuration: Configuration = .live) {
        self.configuration = configuration
    }

    // MARK: - Start

    /// Call once from `ContentView` with the app's stores. Loads the best available bundle, then
    /// checks the server; afterwards every `didBecomeActive` triggers another (throttled) check.
    func start(nodes: NodeStore, settings: SettingsStore, tunnel: TunnelController) {
        guard !started else { return }
        started = true
        self.nodes = nodes
        self.settings = settings
        self.tunnel = tunnel
        refreshSnapshot()

        // Keep the state `getAppState()` returns current without ever blocking on the main thread.
        Publishers.Merge3(nodes.objectWillChange, settings.objectWillChange, tunnel.objectWillChange)
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshSnapshot() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { await self.checkForUpdates() }
            }
            .store(in: &cancellables)

        Task {
            await bootstrap()
            await checkForUpdates(force: true)
        }
    }

    // MARK: - Tier 2 + 3: cache, then the bundle inside the app

    private func bootstrap() async {
        // Cached download on disk, then its UserDefaults mirror, then the starter bundle.
        if let disk = Self.readFiles(), await activate(version: defaults.string(forKey: Key.version) ?? "cached",
                                                       uiText: disk.ui, logic: disk.logic, source: .cached) { return }
        if let ui = defaults.string(forKey: Key.ui), let logic = defaults.string(forKey: Key.logic),
           await activate(version: defaults.string(forKey: Key.version) ?? "cached", uiText: ui, logic: logic, source: .cached) { return }
        if let ui = Self.bundledText("default_ui", "json"), let logic = Self.bundledText("default_logic", "js"),
           await activate(version: "bundled", uiText: ui, logic: logic, source: .bundled) { return }
        ui = nil
        source = .none
    }

    private static func bundledText(_ name: String, _ ext: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Tier 1: remote

    /// Downloads and installs a newer bundle. Safe to call at any time; failures change nothing.
    func checkForUpdates(force: Bool = false) async {
        guard !isChecking else { return }
        if !force, let last = lastAttempt, Date().timeIntervalSince(last) < configuration.minimumCheckInterval { return }
        isChecking = true
        lastAttempt = Date()
        defer { isChecking = false }

        var envelope: Envelope?
        var failure: String?
        for (url, timeout) in endpoints() {
            do {
                envelope = try await fetch(url, timeout: timeout)
                break
            } catch {
                failure = error.localizedDescription
            }
        }
        guard let envelope else {
            lastError = failure ?? "No update endpoint"
            return
        }
        lastChecked = Date()
        if let backup = envelope.backup_url { defaults.set(backup, forKey: Key.backupURL) }

        let haveRemote = source == .remote || source == .cached
        if envelope.unchanged == true || (haveRemote && envelope.version == version) {
            lastError = nil
            return
        }
        guard let uiText = envelope.ui, let logic = envelope.logic else {
            lastError = "The update did not contain ui and logic"
            return
        }
        if let minimum = envelope.min_app_version, !minimum.isEmpty, !Self.appVersion.isAtLeast(minimum) {
            lastError = "Update needs app version \(minimum)"
            return
        }
        guard uiText.utf8.count <= Self.maxBundleBytes, logic.utf8.count <= Self.maxBundleBytes else {
            lastError = "The update is too large"
            return
        }
        guard verifySignature(version: envelope.version, ui: uiText, logic: logic, signature: envelope.signature) else {
            lastError = "The update signature is invalid"
            return
        }
        if await activate(version: envelope.version, uiText: uiText, logic: logic, source: .remote) {
            persist(version: envelope.version, ui: uiText, logic: logic)
            lastError = nil
        }
    }

    private struct Envelope: Decodable {
        var version: String
        var unchanged: Bool?
        var ui: String?
        var logic: String?
        var backup_url: String?
        var min_app_version: String?
        var signature: String?
    }

    /// Primary first; the backup only when it is a different, non-empty https URL.
    private func endpoints() -> [(URL, TimeInterval)] {
        var list: [(URL, TimeInterval)] = []
        if let url = Self.httpsURL(configuration.primaryURL) { list.append((url, configuration.primaryTimeout)) }
        let backup = configuration.backupURL?.nilIfEmpty ?? defaults.string(forKey: Key.backupURL)?.nilIfEmpty
        if let backup, backup != configuration.primaryURL, let url = Self.httpsURL(backup) {
            list.append((url, configuration.backupTimeout))
        }
        return list
    }

    private static func httpsURL(_ string: String) -> URL? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }

    private func fetch(_ url: URL, timeout: TimeInterval) async throws -> Envelope {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw URLError(.badURL) }
        var items = components.queryItems ?? []
        // A fresh query string on every check so a page cache on the host can never answer.
        items.removeAll { $0.name == "t" || $0.name == "v" }
        items.append(URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970 * 1000))))
        if source == .remote || source == .cached { items.append(URLQueryItem(name: "v", value: version)) }
        components.queryItems = items
        guard let requestURL = components.url else { throw URLError(.badURL) }

        var request = URLRequest(url: requestURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        guard data.count <= Self.maxBundleBytes * 3 else { throw URLError(.dataLengthExceedsMaximum) }
        return try JSONDecoder().decode(Envelope.self, from: data)
    }

    // MARK: - Validation and activation

    private func verifySignature(version: String, ui: String, logic: String, signature: String?) -> Bool {
        guard let keyText = configuration.publicKeyBase64?.nilIfEmpty else { return true }
        guard let keyData = Data(base64Encoded: keyText),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let signature, let signatureData = Data(base64Encoded: signature) else { return false }
        func hex(_ text: String) -> String {
            SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let message = "slproxy-ota-v1\n\(version)\n\(hex(ui))\n\(hex(logic))"
        return key.isValidSignature(signatureData, for: Data(message.utf8))
    }

    /// Returns an error text, or nil when the bundle is usable.
    private func validate(uiText: String, logic: String) async -> String? {
        guard let data = uiText.data(using: .utf8), let decoded = try? JSONDecoder().decode(OTAUI.self, from: data) else {
            return "ui.json is not valid"
        }
        guard decoded.schema <= Self.supportedSchema else { return "ui.json schema \(decoded.schema) is newer than this app" }

        let probe = OTAJSRuntime()
        if let error = await probe.load(logic: logic, bridge: .inert) { return error }
        let called = Set(decoded.components.compactMap { $0.action }.filter { $0.type == "js" }.compactMap(\.fn))
        let missing = await probe.missingFunctions(Array(called))
        if !missing.isEmpty { return "logic.js is missing: \(missing.sorted().joined(separator: ", "))" }
        return nil
    }

    /// Validates the bundle and, when it passes, makes it the running one. Returns whether it did.
    @discardableResult
    private func activate(version: String, uiText: String, logic: String, source: Source) async -> Bool {
        if let error = await validate(uiText: uiText, logic: logic) {
            lastError = error
            return false
        }
        guard let data = uiText.data(using: .utf8), let decoded = try? JSONDecoder().decode(OTAUI.self, from: data) else {
            return false
        }
        // A new runtime for the new logic; the old one (stuck or not) is dropped.
        let fresh = OTAJSRuntime()
        if let error = await fresh.load(logic: logic, bridge: makeBridge()) {
            lastError = error
            return false
        }
        runtime = fresh
        runtimeReady = true
        logicText = logic
        self.ui = decoded
        self.version = version
        self.source = source
        refreshSnapshot()
        refreshModal()
        if await fresh.hasFunction("onLoad") { _ = await call("onLoad") }
        return true
    }

    // MARK: - Disk and UserDefaults

    private static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("OTA", isDirectory: true)
    }

    private static func readFiles() -> (ui: String, logic: String)? {
        guard let ui = try? String(contentsOf: directory.appendingPathComponent("ui.json"), encoding: .utf8),
              let logic = try? String(contentsOf: directory.appendingPathComponent("logic.js"), encoding: .utf8) else { return nil }
        return (ui, logic)
    }

    private func persist(version: String, ui: String, logic: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try? ui.write(to: Self.directory.appendingPathComponent("ui.json"), atomically: true, encoding: .utf8)
        try? logic.write(to: Self.directory.appendingPathComponent("logic.js"), atomically: true, encoding: .utf8)
        defaults.set(version, forKey: Key.version)
        defaults.set(ui, forKey: Key.ui)
        defaults.set(logic, forKey: Key.logic)
    }

    // MARK: - Calling JavaScript

    /// Calls a function of `logic.js` off the main thread and returns its result (a Foundation
    /// value) or nil. Errors and timeouts land in `lastError`; a runtime that hung is replaced.
    @discardableResult
    func call(_ function: String, args: [Any] = []) async -> Any? {
        guard runtimeReady else { return nil }
        refreshSnapshot()
        let current = runtime
        let result = await current.call(function, args: args)
        if let error = result.error { lastError = error }
        if result.timedOut || current.isStuck, runtime === current {
            let fresh = OTAJSRuntime()
            if await fresh.load(logic: logicText, bridge: makeBridge()) == nil { runtime = fresh } else { runtimeReady = false }
        }
        return result.value
    }

    // MARK: - Actions from the UI

    func perform(_ action: OTAAction?, from component: OTAComponent? = nil, extraArgs: [Any] = []) {
        guard let action else { return }
        switch action.type {
        case "js":
            guard let fn = action.fn else { return }
            let args = (action.args ?? []).map(\.foundation) + extraArgs
            Task { await call(fn, args: args) }
        case "url":
            if let url = action.url, let target = Self.webURL(url) { UIApplication.shared.open(target) }
        case "toast":
            if let message = action.message { nodes?.toast = String(message.prefix(300)) }
        case "dismiss":
            if let id = component?.id { dismiss(id) }
        default:
            break
        }
    }

    /// http(s) only; callable from the JavaScript queue.
    nonisolated private static func webURL(_ string: String) -> URL? {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else { return nil }
        return url
    }

    // MARK: - Components, flags, modals

    func components(for placement: String) -> [OTAComponent] {
        let dismissed = Set(defaults.stringArray(forKey: Key.dismissed) ?? [])
        return (ui?.components ?? []).filter {
            ["banner", "card", "button", "toggle"].contains($0.type)
                && ($0.placement ?? "home.top") == placement
                && !dismissed.contains($0.id)
                && isActive($0)
        }
    }

    func flag(_ name: String, default fallback: Bool = false) -> Bool {
        flagStore.get(name) ?? ui?.flags?[name] ?? fallback
    }

    func setFlag(_ name: String, _ value: Bool) {
        if flagStore.set(name, value) { flagRevision += 1 }
    }

    func dismiss(_ id: String) {
        var ids = defaults.stringArray(forKey: Key.dismissed) ?? []
        if !ids.contains(id) { ids.append(id) }
        defaults.set(ids, forKey: Key.dismissed)
        objectWillChange.send()
    }

    private func isActive(_ component: OTAComponent, now: Date = Date()) -> Bool {
        if component.enabled == false { return false }
        let formatter = ISO8601DateFormatter()
        if let text = component.startsAt, let date = formatter.date(from: text), now < date { return false }
        if let text = component.expiresAt, let date = formatter.date(from: text), now > date { return false }
        if let minimum = component.minAppVersion, !Self.appVersion.isAtLeast(minimum) { return false }
        return true
    }

    func refreshModal() {
        let seen = Set(defaults.stringArray(forKey: Key.seenModals) ?? [])
        let dismissed = Set(defaults.stringArray(forKey: Key.dismissed) ?? [])
        pendingModal = (ui?.components ?? []).first {
            $0.type == "modal" && isActive($0) && !dismissed.contains($0.id)
                && ($0.showOnce == false || !seen.contains($0.id))
        }
    }

    func markModalSeen(_ component: OTAComponent) {
        var ids = defaults.stringArray(forKey: Key.seenModals) ?? []
        if !ids.contains(component.id) { ids.append(component.id) }
        defaults.set(ids, forKey: Key.seenModals)
    }

    // MARK: - Bridge into the app

    private func makeBridge() -> OTABridge {
        let store = flagStore
        let box = stateBox
        return OTABridge(
            toast: { [weak self] message in
                Task { @MainActor in self?.nodes?.toast = message }
            },
            applyProxyConfig: { [weak self] text in
                // Parsed here, on the JavaScript queue, so the script gets a real answer.
                let parsed = ProxyURLParser.parseMany(String(text.prefix(16_384)))
                guard !parsed.nodes.isEmpty else { return false }
                Task { @MainActor in self?.useServers(parsed.nodes) }
                return true
            },
            setRoutingMode: { [weak self] mode in
                guard let value = RoutingMode(rawValue: mode.lowercased()) else { return false }
                Task { @MainActor in self?.settings?.value.routingMode = value }
                return true
            },
            openURL: { text in
                guard let url = Self.webURL(text) else { return false }
                DispatchQueue.main.async { UIApplication.shared.open(url) }
                return true
            },
            appState: { box.value },
            flags: store,
            log: { message in NSLog("[OTA] %@", message) }
        )
    }

    /// Adds the servers (skipping ones already stored) and selects the first, which makes
    /// `ContentView` call `tunnel.applyChanges()`: a running tunnel switches to it on its own.
    private func useServers(_ parsed: [ProxyNode]) {
        guard let nodes else { return }
        var target: ProxyNode?
        for node in parsed {
            if let existing = nodes.nodes.first(where: {
                $0.kind == node.kind && $0.server == node.server && $0.port == node.port && $0.username == node.username
            }) {
                target = target ?? existing
            } else {
                nodes.add(node)
                target = target ?? node
            }
        }
        if let target { nodes.select(target) }
    }

    private func refreshSnapshot() {
        var state: [String: Any] = [
            "appVersion": Self.appVersion,
            "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0",
            "otaVersion": version,
        ]
        if let nodes {
            state["activeNodeID"] = nodes.activeNodeID?.uuidString ?? ""
            state["activeNodeName"] = nodes.activeNode?.name ?? ""
            state["nodeCount"] = nodes.nodes.count
        }
        if let tunnel {
            let status: String
            switch tunnel.status {
            case .stopped: status = "stopped"
            case .starting: status = "starting"
            case .running: status = "running"
            case .stopping: status = "stopping"
            }
            state["tunnelStatus"] = status
            state["connected"] = tunnel.isConnected
            state["port"] = tunnel.activePort ?? 0
        }
        if let settings {
            state["routingMode"] = settings.value.routingMode.rawValue
            state["navigationStyle"] = settings.value.navigationStyle.rawValue
        }
        stateBox.value = state
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }
}

// MARK: - Small helpers

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Dotted-number comparison: "1.10" is at least "1.9".
    func isAtLeast(_ other: String) -> Bool {
        compare(other, options: .numeric) != .orderedAscending
    }
}
