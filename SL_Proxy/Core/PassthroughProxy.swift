import Foundation
import Network

/// Lightweight TCP passthrough that holds the loopback proxy port while sing-box is not running.
///
/// When the cellular profile is installed it hard-wires the APN proxy to `127.0.0.1:<port>`. If
/// nothing listens on that port after the engine stops, every cellular connection the device makes
/// fails immediately. `PassthroughProxy` keeps the port alive and forwards connections directly to
/// their destination (no proxy node), so the device retains normal internet access.
///
/// Supported protocols (detected by peeking at the first byte):
/// - **HTTP CONNECT** – tunnelled HTTPS and any TCP protocol wrapped in CONNECT.
/// - **Plain HTTP** – absolute-form proxy requests (`GET http://host/…`) and origin-form requests
///   with a `Host` header, forwarded as-is to the origin server.
/// - **SOCKS5** – no-auth handshake + CONNECT command.
///
/// All forwarding is direct (system default route). `start(port:)` returns only once the listener is
/// actually accepting connections; sing-box can take a moment to release its socket after `close()`,
/// so the bind is retried. `stop()` frees the port so sing-box can bind it again.
final class PassthroughProxy {
    /// Bind attempts after the core stopped (`bindRetryDelay` apart) before giving up.
    static let bindAttempts = 12
    static let bindRetryDelay: Duration = .milliseconds(150)

    /// Fires off the main thread when the listener starts serving (`true`) or dies on its own
    /// (`false`: failed or cancelled by the system, not by `stop()`).
    var onStateChange: ((Bool) -> Void)?
    /// Diagnostic sink; `TunnelController` routes it into the engine log.
    var log: ((String) -> Void)?

    private var _isRunning = false
    private var _port: Int?
    private var listener: NWListener?
    private var connections: [UUID: (NWConnection, NWConnection?)] = [:]
    private let queue = DispatchQueue(label: "com.slproxy.passthrough", qos: .utility)
    private let lock = NSLock()

    /// True while the listener is bound and accepting connections.
    var isRunning: Bool { lock.withLock { _isRunning } }
    /// Port currently held; nil while stopped.
    var port: Int? { lock.withLock { _port } }

    // MARK: - Lifecycle

    /// Binds `127.0.0.1:port` and returns once the listener accepts connections. sing-box may still
    /// hold the socket for a moment after `close()`, so the bind is retried `bindAttempts` times.
    /// Returns false when the port could not be taken within that budget.
    @discardableResult
    func start(port: Int) async -> Bool {
        await stop()
        guard (1...65535).contains(port), let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }
        for attempt in 1...Self.bindAttempts {
            if PortProbe.isAvailable(port), await bind(nwPort, port: port) {
                if attempt > 1 {
                    log?("Passthrough proxy: bound \(AppSettings.localProxyHost):\(port) on attempt \(attempt)")
                }
                return true
            }
            try? await Task.sleep(for: Self.bindRetryDelay)
        }
        log?("Passthrough proxy: \(AppSettings.localProxyHost):\(port) stayed busy after \(Self.bindAttempts) attempts")
        return false
    }

    func stop() async {
        let (l, conns): (NWListener?, [UUID: (NWConnection, NWConnection?)]) = lock.withLock {
            let l = listener
            let c = connections
            listener = nil
            connections = [:]
            _isRunning = false
            _port = nil
            return (l, c)
        }
        guard l != nil || !conns.isEmpty else { return }
        l?.cancel()
        for (client, target) in conns.values {
            client.cancel()
            target?.cancel()
        }
        // Give the OS a moment to release the port before sing-box tries to bind it.
        try? await Task.sleep(for: .milliseconds(80))
    }

    // MARK: - Bind

    /// Starts one listener on `127.0.0.1:port` and waits for it to become ready. Returns false when
    /// the system rejects the bind (typically "address already in use").
    private func bind(_ nwPort: NWEndpoint.Port, port: Int) async -> Bool {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(AppSettings.localProxyHost), port: nwPort)
        let l: NWListener
        do {
            l = try NWListener(using: params)
        } catch {
            log?("Passthrough proxy: listener could not be created: \(error.localizedDescription)")
            return false
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }

        let ready: Bool = await withCheckedContinuation { continuation in
            let gate = ResumeGate()
            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if gate.claim() { continuation.resume(returning: true) }
                case .waiting(let error), .failed(let error):
                    self?.log?("Passthrough proxy: listener error: \(error.localizedDescription)")
                    self?.listenerDied(l)
                    if gate.claim() { continuation.resume(returning: false) }
                case .cancelled:
                    self?.listenerDied(l)
                    if gate.claim() { continuation.resume(returning: false) }
                default:
                    break
                }
            }
            l.start(queue: queue)
        }

        if ready {
            lock.withLock {
                listener = l
                _isRunning = true
                _port = port
            }
            onStateChange?(true)
        } else {
            l.cancel()
        }
        return ready
    }

    /// Clears the bookkeeping when the *current* listener stops for a reason other than `stop()`.
    private func listenerDied(_ l: NWListener) {
        let wasCurrent: Bool = lock.withLock {
            guard listener === l else { return false }
            listener = nil
            _isRunning = false
            _port = nil
            return true
        }
        if wasCurrent { onStateChange?(false) }
    }

    /// One-shot flag shared between the listener state callbacks and the awaiting continuation.
    private final class ResumeGate {
        private var resumed = false
        private let lock = NSLock()

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if resumed { return false }
            resumed = true
            return true
        }
    }

    // MARK: - Accept

    private func accept(_ client: NWConnection) {
        let id = UUID()
        lock.withLock { connections[id] = (client, nil) }
        client.start(queue: queue)
        client.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, error in
            guard let self, let data, !data.isEmpty, error == nil else {
                client.cancel(); self?.remove(id); return
            }
            if data[data.startIndex] == 0x05 {
                self.handleSOCKS5(id: id, client: client, initial: data)
            } else {
                self.handleHTTP(id: id, client: client, initial: data)
            }
        }
    }

    // MARK: - HTTP / CONNECT

    private static let headerTerminator = Data("\r\n\r\n".utf8)

    private func handleHTTP(id: UUID, client: NWConnection, initial: Data) {
        let headerEnd = initial.range(of: Self.headerTerminator)
        let headerBytes = headerEnd.map { initial[initial.startIndex..<$0.lowerBound] } ?? initial
        guard let text = String(data: headerBytes, encoding: .utf8) else {
            reject(id: id, client: client, status: "400 Bad Request"); return
        }
        let lines = text.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ").map(String.init)
        guard parts.count >= 2 else {
            reject(id: id, client: client, status: "400 Bad Request"); return
        }

        if parts[0].uppercased() == "CONNECT" {
            guard let (host, port) = splitHostPort(parts[1], defaultPort: 443) else {
                reject(id: id, client: client, status: "400 Bad Request"); return
            }
            // Bytes after the CONNECT header (an eager TLS ClientHello) belong to the tunnel.
            let trailing: Data = headerEnd.map { Data(initial[$0.upperBound...]) } ?? Data()
            openTarget(host: host, port: port, id: id, client: client, onFailure: { [weak self] _ in
                self?.send(client, data: Data("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n".utf8))
            }) { [weak self] target in
                guard let self else { return }
                self.send(client, data: Data("HTTP/1.1 200 Connection established\r\n\r\n".utf8))
                if !trailing.isEmpty { self.send(target, data: trailing) }
                self.splice(id: id, a: client, b: target)
            }
            return
        }

        // Absolute-form proxy request (GET http://host/path) or origin-form (GET /path + Host:).
        var destination: (String, Int)?
        if let url = URL(string: parts[1]), url.scheme != nil, let host = url.host {
            destination = (host, url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80))
        } else if let hostLine = lines.dropFirst().first(where: { $0.lowercased().hasPrefix("host:") }) {
            let value = String(hostLine.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            destination = splitHostPort(value, defaultPort: 80)
        }
        guard let (host, port) = destination else {
            reject(id: id, client: client, status: "400 Bad Request"); return
        }
        openTarget(host: host, port: port, id: id, client: client, onFailure: { [weak self] _ in
            self?.send(client, data: Data("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n".utf8))
        }) { [weak self] target in
            guard let self else { return }
            self.send(target, data: initial)
            self.splice(id: id, a: client, b: target)
        }
    }

    private func reject(id: UUID, client: NWConnection, status: String) {
        send(client, data: Data("HTTP/1.1 \(status)\r\nConnection: close\r\n\r\n".utf8))
        client.cancel()
        remove(id)
    }

    // MARK: - SOCKS5

    private func handleSOCKS5(id: UUID, client: NWConnection, initial: Data) {
        // Greeting: VER NMETHODS METHODS…; answer "no authentication required".
        let methodCount = initial.count > 1 ? Int(initial[initial.startIndex + 1]) : 0
        let greetingLength = 2 + methodCount
        send(client, data: Data([0x05, 0x00]))
        if initial.count > greetingLength {
            // The client pipelined its CONNECT request behind the greeting.
            handleSOCKS5Request(id: id, client: client, data: Data(initial[(initial.startIndex + greetingLength)...]))
            return
        }
        client.receive(minimumIncompleteLength: 4, maximumLength: 512) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else {
                client.cancel(); self?.remove(id); return
            }
            self.handleSOCKS5Request(id: id, client: client, data: data)
        }
    }

    private func handleSOCKS5Request(id: UUID, client: NWConnection, data: Data) {
        guard data.count >= 4 else { client.cancel(); remove(id); return }
        guard data[data.startIndex + 1] == 0x01 else { // only CONNECT is supported
            socksReply(client, code: 0x07); client.cancel(); remove(id); return
        }
        let atyp = data[data.startIndex + 3]
        var host: String?
        var port: UInt16 = 0
        var idx = data.startIndex + 4
        switch atyp {
        case 0x01: // IPv4
            guard data.distance(from: idx, to: data.endIndex) >= 6 else { client.cancel(); remove(id); return }
            host = (0..<4).map { String(data[idx + $0]) }.joined(separator: ".")
            idx += 4; port = UInt16(data[idx]) << 8 | UInt16(data[idx + 1])
        case 0x03: // Domain
            let len = Int(data[idx]); idx += 1
            guard data.distance(from: idx, to: data.endIndex) >= len + 2 else { client.cancel(); remove(id); return }
            host = String(bytes: data[idx..<(idx + len)], encoding: .utf8)
            idx += len; port = UInt16(data[idx]) << 8 | UInt16(data[idx + 1])
        case 0x04: // IPv6
            guard data.distance(from: idx, to: data.endIndex) >= 18 else { client.cancel(); remove(id); return }
            let bytes = Array(data[idx..<(idx + 16)])
            host = stride(from: 0, to: 16, by: 2).map { String(format: "%02x%02x", bytes[$0], bytes[$0 + 1]) }.joined(separator: ":")
            idx += 16; port = UInt16(data[idx]) << 8 | UInt16(data[idx + 1])
        default:
            socksReply(client, code: 0x08); client.cancel(); remove(id); return
        }
        guard let host else { client.cancel(); remove(id); return }
        openTarget(host: host, port: Int(port), id: id, client: client, onFailure: { [weak self] _ in
            self?.socksReply(client, code: 0x05) // connection refused
        }) { [weak self] target in
            guard let self else { return }
            self.socksReply(client, code: 0x00)
            self.splice(id: id, a: client, b: target)
        }
    }

    private func socksReply(_ client: NWConnection, code: UInt8) {
        send(client, data: Data([0x05, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))
    }

    // MARK: - Target connection

    /// Opens the direct connection to the destination. `preferNoProxies` is essential: the carrier
    /// profile makes 127.0.0.1:<port> the system HTTP proxy for cellular, and NWConnection applies
    /// system proxies by default, so without it every outbound connection would be routed straight
    /// back into this listener and loop forever.
    private func openTarget(host: String, port: Int, id: UUID, client: NWConnection,
                            onFailure: ((Error) -> Void)? = nil,
                            onReady: @escaping (NWConnection) -> Void) {
        let params = NWParameters.tcp
        params.preferNoProxies = true
        let target = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? 80,
            using: params
        )
        lock.withLock { connections[id] = (client, target) }
        target.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                onReady(target)
            case .waiting(let error), .failed(let error):
                self.log?("Passthrough proxy: \(host):\(port) unreachable: \(error.localizedDescription)")
                onFailure?(error)
                target.cancel()
                client.cancel()
                self.remove(id)
            case .cancelled:
                client.cancel()
                self.remove(id)
            default:
                break
            }
        }
        target.start(queue: queue)
    }

    // MARK: - Splice

    private func splice(id: UUID, a: NWConnection, b: NWConnection) {
        pump(from: a, to: b, id: id)
        pump(from: b, to: a, id: id)
    }

    private func pump(from src: NWConnection, to dst: NWConnection, id: UUID) {
        src.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.send(dst, data: data) }
            if isComplete || error != nil { dst.cancel(); self.remove(id); return }
            self.pump(from: src, to: dst, id: id)
        }
    }

    private func send(_ conn: NWConnection, data: Data) { conn.send(content: data, completion: .idempotent) }
    private func remove(_ id: UUID) { lock.withLock { _ = connections.removeValue(forKey: id) } }

    private func splitHostPort(_ hostPort: String, defaultPort: Int) -> (String, Int)? {
        if hostPort.hasPrefix("[") {
            guard let close = hostPort.firstIndex(of: "]") else { return nil }
            let host = String(hostPort[hostPort.index(after: hostPort.startIndex)..<close])
            let rest = hostPort[hostPort.index(after: close)...]
            return (host, rest.hasPrefix(":") ? Int(rest.dropFirst()) ?? defaultPort : defaultPort)
        }
        let parts = hostPort.split(separator: ":", maxSplits: 1)
        guard let host = parts.first.map(String.init), !host.isEmpty else { return nil }
        return (host, parts.count > 1 ? Int(parts[1]) ?? defaultPort : defaultPort)
    }
}
