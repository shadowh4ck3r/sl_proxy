import Foundation
import Network
import OSLog

/// Tiny HTTP server that hands out the proxy auto-config script for Proxy Share.
///
/// sing-box's mixed inbound only speaks proxy protocols, so the PAC file is served by this
/// Network.framework listener bound to the same interface address as the shared listener, on its
/// own port. A tethered device enters one URL (`http://<address>:<port>/proxy.pac`) under Wi-Fi >
/// Configure Proxy > Automatic and reads the proxy address from the script. `TunnelController`
/// starts and stops it together with the share listener.
final class PACServer {
    static let scriptPath = "/proxy.pac"
    static let contentType = "application/x-ns-proxy-autoconfig"

    enum ServerError: LocalizedError {
        case invalidPort(Int)
        case failed(Error)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .invalidPort(let port): return "PAC port \(port) is not a valid TCP port."
            case .failed(let error): return "PAC listener failed: \(error.localizedDescription)"
            case .cancelled: return "PAC listener was cancelled before it started."
            }
        }
    }

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? AppGroup.appBundleID, category: "pac")
    /// Listener and connection callbacks run here; `connections` is only touched on this queue.
    private let queue = DispatchQueue(label: "com.slproxy.userspace.pac")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var script = Data()

    private let stateLock = NSLock()
    private var _endpoint: (host: String, port: Int)?

    var isRunning: Bool { stateLock.withLock { _endpoint != nil } }
    var boundPort: Int? { stateLock.withLock { _endpoint?.port } }

    /// Calls `body` at most once even when several listener states arrive.
    private final class Once {
        private var done = false
        func run(_ body: () -> Void) {
            guard !done else { return }
            done = true
            body()
        }
    }

    // MARK: - Control

    /// Binds `host:port` (0.0.0.0 for the HOTSPOT wildcard) and serves `script`, replacing a
    /// running instance. Returns once the listener is ready or throws the bind error.
    func start(host: String, port: Int, script: String) async throws {
        await stop()
        guard (1...65535).contains(port), let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw ServerError.invalidPort(port)
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if host != ShareInterface.wildcardAddress {
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: nwPort)
        }
        let listener = try NWListener(using: parameters, on: nwPort)
        self.script = Data(script.utf8)
        self.listener = listener

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once()
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.stateLock.withLock { self._endpoint = (host, port) }
                    self.log.info("PAC listener ready on \(host, privacy: .public):\(port)")
                    once.run { continuation.resume() }
                case .failed(let error):
                    self.stateLock.withLock { self._endpoint = nil }
                    self.log.error("PAC listener failed: \(error.localizedDescription, privacy: .public)")
                    once.run { continuation.resume(throwing: ServerError.failed(error)) }
                case .cancelled:
                    self.stateLock.withLock { self._endpoint = nil }
                    once.run { continuation.resume(throwing: ServerError.cancelled) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: self.queue)
        }
    }

    /// Closes the listener and every open connection; returns once the socket is released so the
    /// port can be probed or rebound immediately.
    func stop() async {
        guard let listener else { return }
        self.listener = nil
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                for connection in self.connections.values { connection.cancel() }
                self.connections.removeAll()
                let once = Once()
                switch listener.state {
                case .cancelled, .failed:
                    once.run { continuation.resume() }
                default:
                    listener.stateUpdateHandler = { state in
                        switch state {
                        case .cancelled, .failed:
                            once.run { continuation.resume() }
                        default:
                            break
                        }
                    }
                    listener.cancel()
                    // Safety net: never hang the caller if the cancelled state does not arrive.
                    self.queue.asyncAfter(deadline: .now() + 2) { once.run { continuation.resume() } }
                }
            }
        }
        stateLock.withLock { _endpoint = nil }
    }

    // MARK: - Script

    /// PAC script that points every request at the Proxy Share listener. Plain host names and,
    /// when `bypassPrivate` is on, private IPv4 literals go DIRECT so LAN devices stay reachable;
    /// everything else uses the HTTP proxy with SOCKS as the fallback. Credentials cannot be
    /// embedded in a PAC file; with authentication on, the client asks for them once.
    static func script(proxyHost: String, proxyPort: Int, bypassPrivate: Bool) -> String {
        let endpoint = "\(proxyHost):\(proxyPort)"
        var lines = [
            "// SL_Proxy proxy auto-config for Proxy Share. Shared listener: \(endpoint)",
            "function FindProxyForURL(url, host) {",
            "  if (isPlainHostName(host) || shExpMatch(host, \"*.local\") || host == \"localhost\") return \"DIRECT\";",
        ]
        if bypassPrivate {
            lines += [
                "  if (/^\\d{1,3}(\\.\\d{1,3}){3}$/.test(host) && (",
                "      isInNet(host, \"10.0.0.0\", \"255.0.0.0\") ||",
                "      isInNet(host, \"172.16.0.0\", \"255.240.0.0\") ||",
                "      isInNet(host, \"192.168.0.0\", \"255.255.0.0\") ||",
                "      isInNet(host, \"127.0.0.0\", \"255.0.0.0\"))) return \"DIRECT\";",
            ]
        }
        lines += [
            "  return \"PROXY \(endpoint); SOCKS \(endpoint)\";",
            "}",
            "",
        ]
        return lines.joined(separator: "\n")
    }

    // MARK: - HTTP

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.connections[key] = nil
            default:
                break
            }
        }
        connection.start(queue: queue)
        // PAC requests are a few hundred bytes; one read covers the request line and headers.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, error in
            guard let self, error == nil, let data, !data.isEmpty else {
                connection.cancel()
                return
            }
            let response = self.response(for: String(decoding: data, as: UTF8.self))
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func response(for request: String) -> Data {
        let requestLine = request.components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ")
        let method = parts.first.map { String($0).uppercased() } ?? "GET"
        var path = parts.count > 1 ? String(parts[1]) : "/"
        if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
        let headOnly = method == "HEAD"

        guard method == "GET" || headOnly else {
            return Self.http(
                status: "405 Method Not Allowed",
                contentType: "text/plain; charset=utf-8",
                body: Data("Method not allowed\n".utf8),
                headOnly: false,
                extraHeaders: ["Allow: GET, HEAD"]
            )
        }
        switch path {
        case Self.scriptPath, "/wpad.dat", "/":
            return Self.http(status: "200 OK", contentType: Self.contentType, body: script, headOnly: headOnly)
        default:
            return Self.http(
                status: "404 Not Found",
                contentType: "text/plain; charset=utf-8",
                body: Data("Not found. The proxy auto-config script is at \(Self.scriptPath)\n".utf8),
                headOnly: headOnly
            )
        }
    }

    private static func http(
        status: String,
        contentType: String,
        body: Data,
        headOnly: Bool,
        extraHeaders: [String] = []
    ) -> Data {
        var head = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Cache-Control: no-cache\r\n"
            + "Connection: close\r\n"
            + "Server: SL_Proxy\r\n"
        for header in extraHeaders { head += header + "\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        if !headOnly { data.append(body) }
        return data
    }
}
