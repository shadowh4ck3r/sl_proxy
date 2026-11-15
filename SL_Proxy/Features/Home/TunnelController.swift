import Combine
import Foundation
import UIKit

/// Owns the in-process sing-box engine for the user-space loopback build.
///
/// Nothing here touches NetworkExtension. Connect starts `LocalProxyEngine` inside the app with a
/// mixed (HTTP + SOCKS5) inbound on 127.0.0.1 and the port chosen in Settings (default 20080). Ports
/// are probed with `PortProbe` before the core binds them: when the chosen loopback port is taken
/// the preset alternatives are tried, then the first free port above it (fallback enabled). When
/// Proxy Share is on, a second mixed inbound is bound to the IPv4 address of the selected interface
/// (Wi-Fi, cellular, or the Personal Hotspot bridge100 gateway 172.20.10.1 with a 0.0.0.0 fallback
/// while the bridge is down); a busy share port is replaced by the first free one scanning upward
/// (port + 1, port + 2, ...) and the port actually bound is published as `activeSharePort`. Next to
/// the share listener the controller runs `ConnectedClientsMonitor` (devices using the shared
/// proxy, from the Clash API) and, when enabled, `PACServer` (proxy auto-config script on
/// `pacURL`). Selecting another server or changing settings regenerates the config and hot-swaps
/// the running core. While the engine runs, `BackgroundKeepAlive` stops iOS from suspending the
/// app when it is minimized (if enabled in Settings). Other apps reach the proxy via the Wi-Fi HTTP
/// proxy setting or their own SOCKS5 option.
///
/// The class keeps the name and surface of the system VPN build (`main`) so the UI is unchanged.
@MainActor
final class TunnelController: ObservableObject {
    enum Status: Equatable {
        case stopped, starting, running, stopping
    }

    /// Bind retries after a probe said a port was free but the core still hit "address in use".
    private static let maxBindAttempts = 4

    @Published private(set) var status: Status = .stopped
    @Published private(set) var isBusy = false
    @Published var lastError: String?
    @Published private(set) var connectedSince: Date?
    /// Server the running core was last configured with (diagnostics).
    @Published private(set) var activeServerName: String?
    /// True while the silent-audio / background-task keep-alive holds the process open.
    @Published private(set) var backgroundKeepAliveActive = false
    /// Port the running core is bound to; nil while stopped. Differs from the Settings value only
    /// when the chosen port was busy and a fallback port was used.
    @Published private(set) var activePort: Int?
    /// Port of the Proxy Share listener the running core is bound to; nil while stopped, while
    /// sharing is off, or when the selected interface had no address. Differs from the Settings
    /// value when the chosen port was busy and the upward scan picked another one.
    @Published private(set) var activeSharePort: Int?
    /// IPv4 address of the interface the Proxy Share listener is bound to (see `activeSharePort`).
    @Published private(set) var activeShareAddress: String?
    /// Port the PAC server is bound to on `activeShareAddress`; nil while it is off or not running.
    @Published private(set) var activePACPort: Int?

    let traffic = TrafficMonitor()
    let clients = ConnectedClientsMonitor()
    let engine = LocalProxyEngine()
    let keepAlive = BackgroundKeepAlive()
    /// Fires a notification when the app is killed while it holds the loopback port.
    private let watchdog = EngineWatchdog()
    let pac = PACServer()
    /// Shared cellular / Wi-Fi path state.
    let path = NetworkPathObserver.shared
    /// Confirms the carrier profile is delivering cellular traffic to the loopback inbound.
    let verifier: ProfileVerifier
    /// Cellular byte counter with daily / monthly caps.
    let budget: DataBudgetTracker
    /// Evaluates on-demand rules on every network path change.
    private(set) var onDemand: OnDemandEngine?
    /// True while the on-demand engine is active (for the Home badge).
    @Published private(set) var onDemandActive = false
    /// True while the passthrough proxy holds the port (engine stopped, profile still installed).
    @Published private(set) var passthroughActive = false
    /// Holds the loopback proxy port with a direct passthrough while sing-box is not running,
    /// so a device with the cellular profile installed never loses internet on disconnect.
    let passthroughProxy = PassthroughProxy()
    /// Port the passthrough is meant to hold: set on disconnect, cleared by a successful connect. Lets
    /// a failed connect or a return to the foreground re-arm the listener.
    private var passthroughPort: Int?

    /// `host:port` other apps connect to: the live port while running, otherwise the configured one.
    var proxyEndpoint: String {
        LocalProxyEngine.endpointDescription(port: activePort ?? settings.value.effectiveLocalProxyPort)
    }

    /// True when the core runs on a fallback port instead of the one chosen in Settings.
    var isOnFallbackPort: Bool {
        guard let activePort else { return false }
        return activePort != settings.value.effectiveLocalProxyPort
    }

    /// `host:port` of the Proxy Share listener while it runs, e.g. `192.168.1.20:10808`.
    var shareEndpoint: String? {
        guard let activeShareAddress, let activeSharePort else { return nil }
        return "\(activeShareAddress):\(activeSharePort)"
    }

    /// True when the Proxy Share listener runs on a port above the one chosen in Settings.
    var isOnFallbackSharePort: Bool {
        guard let activeSharePort else { return false }
        return activeSharePort != settings.value.effectiveSharePort
    }

    /// Address other devices use to reach the Proxy Share listener: the bound address while
    /// running, otherwise the address the current settings would bind. The HOTSPOT wildcard
    /// (0.0.0.0) is reported as the bridge100 gateway 172.20.10.1, which is what tethered clients
    /// actually dial. Nil while sharing is off or the interface has no address.
    var shareAdvertisedAddress: String? {
        guard let address = activeShareAddress ?? SingBoxConfigBuilder.shareListenAddress(settings.value) else {
            return nil
        }
        return address == ShareInterface.wildcardAddress ? ShareInterface.hotspotGatewayAddress : address
    }

    /// Share port other devices use: the live one while running, otherwise the configured one.
    var shareAdvertisedPort: Int {
        activeSharePort ?? settings.value.effectiveSharePort
    }

    /// `host:port` printed on the QR code and in the PAC script (see `shareAdvertisedAddress`).
    var shareAdvertisedEndpoint: String? {
        shareAdvertisedAddress.map { "\($0):\(shareAdvertisedPort)" }
    }

    /// URL of the proxy auto-config script: the live PAC port while the server runs, otherwise the
    /// configured one when PAC is enabled. Nil when PAC is off or sharing has no address.
    var pacURL: String? {
        guard let address = shareAdvertisedAddress else { return nil }
        guard let port = activePACPort ?? (settings.value.pacEnabled ? settings.value.effectivePACPort : nil) else {
            return nil
        }
        return "http://\(address):\(port)\(PACServer.scriptPath)"
    }

    private let nodes: NodeStore
    private let settings: SettingsStore
    private var applyTask: Task<Void, Never>?
    /// Config the running core was started with; used to skip no-op restarts.
    private var appliedConfig: String?
    /// PAC settings the running PAC server was started with (not part of the sing-box config).
    private var appliedPACKey: String?
    /// Port Settings asked for when the running config was generated.
    private var requestedPort: Int?
    /// Proxy Share port Settings asked for when the running config was generated.
    private var requestedSharePort: Int?
    private var cancellables = Set<AnyCancellable>()

    init(nodes: NodeStore, settings: SettingsStore) {
        self.nodes = nodes
        self.settings = settings
        verifier = ProfileVerifier(path: path)
        budget = DataBudgetTracker(settings: settings, path: path)
        budget.attach(to: traffic)
        budget.onLimitReached = { [weak self] period, cap in
            self?.enforceBudget(period, cap: cap)
        }

        // A fresh launch: clear any "stopped" alert left over from the previous run.
        watchdog.stop()

        keepAlive.$isActive
            .receive(on: RunLoop.main)
            .assign(to: &$backgroundKeepAliveActive)
        keepAlive.$lastProblem
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] problem in
                self?.engine.record("Background keep-alive: \(problem)")
            }
            .store(in: &cancellables)

        // Passthrough diagnostics go to the engine log; its listener state drives the DIRECT badge.
        let engine = self.engine
        passthroughProxy.log = { line in engine.record(line) }
        passthroughProxy.onStateChange = { [weak self] running in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.passthroughActive = running
                if !running, self.passthroughPort != nil, self.status == .stopped {
                    self.engine.record("Passthrough proxy: listener closed unexpectedly; it is re-armed when SL_Proxy returns to the foreground")
                }
                self.syncKeepAlive()
            }
        }
        // iOS may have suspended the process (keep-alive off or expired); put the port back.
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in await self?.resumePassthroughIfNeeded() }
            }
            .store(in: &cancellables)

        // Wire the on-demand engine; it starts/stops with the on-demand setting.
        let od = OnDemandEngine(tunnel: self, settings: settings)
        onDemand = od
        settings.$value
            .map(\.onDemandEnabled)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak od] enabled in
                guard let self, let od else { return }
                if enabled { od.start() } else { od.stop() }
                self.onDemandActive = enabled
            }
            .store(in: &cancellables)
        if settings.value.onDemandEnabled {
            od.start()
            onDemandActive = true
        }

        if settings.value.autoConnectOnLaunch, nodes.activeNode != nil {
            Task { await start() }
        }
    }

    // MARK: - State

    var isConnected: Bool { status == .running }

    var isTransitioning: Bool { status == .starting || status == .stopping }

    var statusText: String {
        switch status {
        case .running: return "Connected"
        case .starting: return "Connecting…"
        case .stopping: return "Disconnecting…"
        case .stopped: return "Disconnected"
        }
    }

    // MARK: - Actions

    func toggle() {
        Task {
            if status == .running || status == .starting {
                await stop()
            } else {
                await start()
            }
        }
    }

    /// Starts the core with the active server, or hot-swaps its configuration when it is already
    /// running. Every listener port is probed first (`PortProbe`): the chosen loopback port, then
    /// the presets, then upward when the fallback is on; the Proxy Share port, then upward. Should
    /// the core still report "address already in use" (a port taken between probe and bind), the
    /// busy port is moved up and the start retried. The engine listens on `proxyEndpoint` (and
    /// `shareEndpoint` when sharing is on) once this returns without an error; the PAC server and
    /// the connected-clients monitor follow the share listener.
    func start() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        lastError = nil
        let wasRunning = status == .running
        // Port the passthrough was holding; restored if this connect fails.
        let heldPort = passthroughPort
        do {
            guard let node = nodes.activeNode else { throw NodeStoreError.noActiveNode }
            // Over the cellular cap with auto-disconnect on: do not start on cellular at all.
            if settings.value.budgetAutoDisconnect, path.isCellular, let period = budget.exceededPeriod {
                throw TunnelStartError.budgetExceeded(period)
            }
            var perPort = settings.value
            let requestedLocal = perPort.effectiveLocalProxyPort
            let requestedShare = perPort.effectiveSharePort
            let shareHost = SingBoxConfigBuilder.shareListenAddress(perPort)
            if perPort.shareEnabled, shareHost == nil {
                engine.record(
                    "Proxy Share: \(perPort.shareInterface.rawValue) has no IPv4 address right now; "
                        + "only the loopback listener is started"
                )
            }
            if perPort.shareEnabled, perPort.shareInterface == .hotspot, shareHost == ShareInterface.wildcardAddress {
                engine.record(
                    "Proxy Share: HOTSPOT bridge100 is down (no tethered client yet); binding \(ShareInterface.wildcardAddress) "
                        + "so clients reach \(ShareInterface.hotspotGatewayAddress):\(requestedShare) once Personal Hotspot is up"
                )
            }
            if perPort.shareEnabled, perPort.shareAuthEnabled, perPort.shareCredentials == nil {
                engine.record("Proxy Share: authentication is on but username or password is blank; the shared listener stays open")
            }
            var config = try nodes.writeActiveConfig(settings: perPort)
            // Hand-entered servers have no share link; ProxyEndpoint also understands the JSON.
            let rawConfig = node.shareURL ?? config
            guard ProxyEndpoint.parse(rawConfig) != nil else {
                throw TunnelStartError.unreadableConfig
            }

            // Ports the running core holds are free again once it is replaced, so a hot swap must
            // not treat its own listener as a collision.
            let owned = ownedEndpoints
            // Stop the passthrough before sing-box tries to bind the same port.
            await passthroughProxy.stop()
            passthroughActive = false
            passthroughPort = nil
            status = .starting
            var localPort = try pickLocalPort(perPort, owned: owned)
            var sharePort = try shareHost.map { try pickSharePort(perPort, host: $0, owned: owned) }
            var attempt = 0
            while true {
                perPort.localProxyPort = localPort
                if let sharePort { perPort.sharePort = sharePort }
                config = try nodes.writeActiveConfig(settings: perPort)
                do {
                    try await engine.start(config: config, port: localPort)
                    break
                } catch where LocalProxyEngine.isAddressInUse(error) && attempt < Self.maxBindAttempts {
                    // The previous core is already closed at this point, so plain probes apply. Move
                    // whatever is busy up; when neither probe sees the collision move a port anyway
                    // so the loop cannot spin on the same pair.
                    attempt += 1
                    var moved = false
                    if !PortProbe.isAvailable(localPort) {
                        guard perPort.localProxyPortFallback else { throw error }
                        localPort = try Self.scanUpward(from: localPort + 1, host: AppSettings.localProxyHost, owned: [])
                        moved = true
                    }
                    if let shareHost, let current = sharePort, !PortProbe.isAvailable(current, host: shareHost) {
                        sharePort = try Self.scanUpward(from: current + 1, host: shareHost, owned: [])
                        moved = true
                    }
                    if !moved {
                        if let shareHost, let current = sharePort {
                            sharePort = try Self.scanUpward(from: current + 1, host: shareHost, owned: [])
                        } else if perPort.localProxyPortFallback {
                            localPort = try Self.scanUpward(from: localPort + 1, host: AppSettings.localProxyHost, owned: [])
                        } else {
                            throw error
                        }
                    }
                    var line = "Bind failed (attempt \(attempt)); retrying on \(LocalProxyEngine.endpointDescription(port: localPort))"
                    if let shareHost, let sharePort { line += " and \(shareHost):\(sharePort)" }
                    engine.record(line)
                }
            }
            if localPort != requestedLocal {
                engine.record(
                    "Bound to \(LocalProxyEngine.endpointDescription(port: localPort)) because \(requestedLocal) was busy; "
                        + "point the apps that use the proxy at this port"
                )
            }
            if let shareHost, let sharePort {
                var line = "Proxy Share: HTTP + SOCKS5 also listening on \(shareHost):\(sharePort) (\(perPort.shareInterface.rawValue))"
                if sharePort != requestedShare { line += "; \(requestedShare) was busy" }
                if perPort.shareCredentials != nil { line += "; username/password required" }
                engine.record(line)
            }
            appliedConfig = config
            appliedPACKey = Self.pacKey(perPort)
            requestedPort = requestedLocal
            activePort = localPort
            requestedSharePort = shareHost != nil ? requestedShare : nil
            activeSharePort = sharePort
            activeShareAddress = shareHost
            status = .running
            activeServerName = node.name
            if !wasRunning || connectedSince == nil { connectedSince = Date() }
            traffic.start()
            verifier.start(port: localPort)
            if shareHost != nil { clients.start() } else { clients.stop() }
            await syncPAC(perPort, shareHost: shareHost, sharePort: sharePort, localPort: localPort)
            syncKeepAlive()
        } catch {
            appliedConfig = nil
            appliedPACKey = nil
            requestedPort = nil
            requestedSharePort = nil
            activePort = nil
            activeSharePort = nil
            activeShareAddress = nil
            status = .stopped
            connectedSince = nil
            activeServerName = nil
            traffic.stop()
            verifier.stop()
            clients.stop()
            await pac.stop()
            activePACPort = nil
            if let heldPort, !passthroughProxy.isRunning {
                // The connect failed: put the passthrough back so the cellular profile keeps working.
                await startPassthrough(port: heldPort)
            } else {
                passthroughPort = heldPort
                syncKeepAlive()
            }
            if LocalProxyEngine.isAddressInUse(error) {
                lastError = "No free port could be bound. Choose another port in Settings > Local proxy "
                    + "or in Proxy Share Settings.\n\n" + error.localizedDescription
            } else {
                lastError = error.localizedDescription
            }
        }
    }

    /// Stops the core and hands the loopback port to `PassthroughProxy`. The background keep-alive is
    /// deliberately left running until `startPassthrough` has settled (see `syncKeepAlive`): releasing
    /// it first let iOS suspend the app between the core closing and the passthrough binding, which
    /// left the cellular profile pointing at a dead port.
    func stop() async {
        guard status == .running || status == .starting else { return }
        status = .stopping
        await pac.stop()
        activePACPort = nil
        // Capture the port before clearing it so the passthrough can bind the same one.
        let lastPort = activePort ?? settings.value.effectiveLocalProxyPort
        await engine.stop()
        appliedConfig = nil
        appliedPACKey = nil
        requestedPort = nil
        requestedSharePort = nil
        activePort = nil
        activeSharePort = nil
        activeShareAddress = nil
        status = .stopped
        connectedSince = nil
        activeServerName = nil
        traffic.stop()
        verifier.stop()
        clients.stop()
        // Hold the port with a direct passthrough so the cellular profile never loses internet.
        await startPassthrough(port: lastPort)
    }

    /// Re-binds the passthrough when it should be holding the port but the listener is gone (for
    /// example after iOS suspended the app with the keep-alive off). Safe to call at any time.
    func resumePassthroughIfNeeded() async {
        guard status == .stopped, let port = passthroughPort, !passthroughProxy.isRunning else { return }
        engine.record("Passthrough proxy: re-arming \(LocalProxyEngine.endpointDescription(port: port))")
        await startPassthrough(port: port)
    }

    /// Binds the passthrough on `port`, publishes the real listener state and keeps the process
    /// alive while it holds the port. Failures are logged; the badge then stays grey instead of
    /// showing DIRECT for a socket nobody is serving.
    private func startPassthrough(port: Int) async {
        passthroughPort = port
        let bound = await passthroughProxy.start(port: port)
        passthroughActive = bound
        if bound {
            engine.record(
                "Passthrough proxy holding \(LocalProxyEngine.endpointDescription(port: port)); "
                    + "cellular traffic goes direct until you reconnect"
            )
        } else {
            engine.record(
                "Passthrough proxy could not bind \(LocalProxyEngine.endpointDescription(port: port)); "
                    + "apps using the cellular profile have no internet until you reconnect"
            )
        }
        syncKeepAlive()
    }

    /// Data Budget: a cellular sample landed at or above a cap. With auto-disconnect on, the
    /// engine is stopped and Home explains why; otherwise the notification alone is the warning.
    private func enforceBudget(_ period: DataBudgetTracker.Period, cap: Int64) {
        guard settings.value.budgetAutoDisconnect, status == .running || status == .starting else { return }
        engine.record("Data Budget: \(period.title.lowercased()) cellular cap of \(TrafficMonitor.bytes(cap)) reached; disconnecting")
        Task { [weak self] in
            guard let self else { return }
            await self.stop()
            self.lastError = TunnelStartError.budgetExceeded(period).localizedDescription
        }
    }

    /// Same as `start()`: the engine replaces the running core in place.
    func restart() async {
        await start()
    }

    /// Called when the active node or settings change. The keep-alive follows the setting at once;
    /// the core is only restarted (after a short debounce) when the generated config or the PAC
    /// settings differ.
    func applyChanges() {
        syncKeepAlive()
        applyTask?.cancel()
        applyTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self, self.status == .running || self.status == .starting else { return }
            // Compare against the ports that actually run while the request is unchanged, so a core
            // that landed on a fallback port is not restarted over and over.
            var reference = self.settings.value
            if let requested = self.requestedPort, let active = self.activePort,
               reference.effectiveLocalProxyPort == requested {
                reference.localProxyPort = active
            }
            if let requested = self.requestedSharePort, let active = self.activeSharePort,
               reference.effectiveSharePort == requested {
                reference.sharePort = active
            }
            if let current = self.nodes.previewConfig(settings: reference),
               current == self.appliedConfig,
               Self.pacKey(reference) == self.appliedPACKey {
                return
            }
            await self.start()
        }
    }

    /// Answers the same requests the tunnel extension used to receive over IPC, straight from the
    /// in-process engine, so the Logs tab and diagnostics work unchanged.
    func send(_ request: TunnelRequest) async -> TunnelReply? {
        var reply = TunnelReply(running: engine.isRunning, startedAt: engine.startedAt, lastError: engine.lastError)
        reply.appGroupAvailable = nil
        reply.configSource = "in-process (user-space)"
        switch request {
        case .status:
            break
        case .logs(let after):
            let page = engine.logs.lines(after: after)
            reply.logs = page.lines
            reply.nextLogIndex = page.next
        case .clearLogs:
            engine.logs.clear()
        }
        return reply
    }

    // MARK: - PAC

    /// Settings that shape the PAC server but not the sing-box config; a change restarts it.
    private static func pacKey(_ s: AppSettings) -> String {
        "\(s.pacEnabled)|\(s.effectivePACPort)"
    }

    /// Starts the PAC server next to the Proxy Share listener, or leaves it stopped when PAC is
    /// off or sharing is not active. A PAC failure is logged and never fatal: the proxy keeps running.
    private func syncPAC(_ s: AppSettings, shareHost: String?, sharePort: Int?, localPort: Int) async {
        await pac.stop()
        activePACPort = nil
        guard s.pacEnabled, let shareHost, let sharePort else { return }
        let advertised = shareHost == ShareInterface.wildcardAddress ? ShareInterface.hotspotGatewayAddress : shareHost
        do {
            let port = try pickPACPort(s, host: shareHost, excluding: [sharePort, localPort])
            let script = PACServer.script(proxyHost: advertised, proxyPort: sharePort, bypassPrivate: s.bypassLAN)
            try await pac.start(host: shareHost, port: port, script: script)
            activePACPort = port
            var line = "Proxy Share: PAC script at http://\(advertised):\(port)\(PACServer.scriptPath)"
            if port != s.effectivePACPort { line += " (\(s.effectivePACPort) was busy)" }
            engine.record(line)
        } catch {
            engine.record("Proxy Share: PAC server did not start: \(error.localizedDescription)")
        }
    }

    /// PAC port to serve on: the chosen port when free on `host` and not one of the proxy ports,
    /// otherwise the first free port above it. The PAC server is already stopped when this runs,
    /// so plain probes apply.
    private func pickPACPort(_ s: AppSettings, host: String, excluding taken: Set<Int>) throws -> Int {
        let preferred = s.effectivePACPort
        if !taken.contains(preferred), PortProbe.isAvailable(preferred, host: host) { return preferred }
        engine.record("Proxy Share: PAC port \(preferred) on \(host) is in use; scanning upward")
        var port = preferred + 1
        var tried = 0
        while port <= AppSettings.localProxyPortRange.upperBound, tried < PortProbe.maxUpwardScan {
            if !taken.contains(port), AppSettings.isValidLocalProxyPort(port), PortProbe.isAvailable(port, host: host) {
                return port
            }
            port += 1
            tried += 1
        }
        throw TunnelStartError.noFreePort(host: host, from: preferred + 1)
    }

    // MARK: - Port selection

    /// `host:port` endpoints the running core (and PAC server) currently hold.
    private var ownedEndpoints: Set<String> {
        var owned = Set<String>()
        guard status == .running || status == .starting else { return owned }
        if let activePort { owned.insert(LocalProxyEngine.endpointDescription(port: activePort)) }
        if let shareEndpoint { owned.insert(shareEndpoint) }
        if let activeShareAddress, let activePACPort { owned.insert("\(activeShareAddress):\(activePACPort)") }
        return owned
    }

    private static func isFree(_ port: Int, host: String, owned: Set<String>) -> Bool {
        owned.contains("\(host):\(port)") || PortProbe.isAvailable(port, host: host)
    }

    /// Loopback port to start on: the chosen port when free, otherwise (fallback enabled) the first
    /// free preset, then the first free port above the chosen one. With the fallback off the chosen
    /// port is returned even when busy so the core reports the collision.
    private func pickLocalPort(_ s: AppSettings, owned: Set<String>) throws -> Int {
        let candidates = s.localProxyPortCandidates
        if let free = candidates.first(where: { Self.isFree($0, host: AppSettings.localProxyHost, owned: owned) }) {
            if free != candidates[0] {
                engine.record("Port \(candidates[0]) is already in use by another proxy tool; using preset \(free)")
            }
            return free
        }
        guard s.localProxyPortFallback else { return candidates[0] }
        engine.record(
            "Ports \(candidates.map(String.init).joined(separator: ", ")) are all in use; "
                + "scanning upward from \(candidates[0] + 1)"
        )
        return try Self.scanUpward(from: candidates[0] + 1, host: AppSettings.localProxyHost, owned: owned)
    }

    /// Proxy Share port to start on: the chosen port when free on `host`, otherwise the first free
    /// port above it (port + 1, port + 2, ...).
    private func pickSharePort(_ s: AppSettings, host: String, owned: Set<String>) throws -> Int {
        let preferred = s.effectiveSharePort
        if Self.isFree(preferred, host: host, owned: owned) { return preferred }
        engine.record("Proxy Share: port \(preferred) on \(host) is in use; scanning upward")
        return try Self.scanUpward(from: preferred + 1, host: host, owned: owned)
    }

    /// First valid port from `start` upward that a TCP listener can bind on `host`.
    private static func scanUpward(from start: Int, host: String, owned: Set<String>) throws -> Int {
        var port = start
        var tried = 0
        while port <= AppSettings.localProxyPortRange.upperBound, tried < PortProbe.maxUpwardScan {
            if AppSettings.isValidLocalProxyPort(port), isFree(port, host: host, owned: owned) { return port }
            port += 1
            tried += 1
        }
        throw TunnelStartError.noFreePort(host: host, from: start)
    }

    // MARK: - Private

    /// The process must stay alive while anything holds the loopback port: the running core, or the
    /// passthrough that replaces it after a disconnect. Both follow the keep-alive setting.
    private func syncKeepAlive() {
        let holdsPort = status == .running || (status == .stopped && passthroughActive)
        if holdsPort && settings.value.keepAliveInBackground {
            keepAlive.start()
        } else {
            keepAlive.stop()
        }
        if holdsPort && settings.value.engineWatchdog {
            watchdog.start()
        } else {
            watchdog.stop()
        }
    }

    enum TunnelStartError: LocalizedError {
        case unreadableConfig
        case noFreePort(host: String, from: Int)
        case budgetExceeded(DataBudgetTracker.Period)

        var errorDescription: String? {
            switch self {
            case .unreadableConfig:
                return "The selected config has no readable server address or port."
            case .noFreePort(let host, let from):
                let upper = min(from + PortProbe.maxUpwardScan - 1, AppSettings.localProxyPortRange.upperBound)
                return "No free TCP port on \(host) between \(from) and \(upper). Choose another port in Settings."
            case .budgetExceeded(let period):
                return "Your \(period.title.lowercased()) cellular data cap is reached, so the proxy was disconnected to avoid overages. "
                    + "Connect on Wi-Fi, or raise the cap / reset usage in Advanced & Pro > Data Budget."
            }
        }
    }
}
