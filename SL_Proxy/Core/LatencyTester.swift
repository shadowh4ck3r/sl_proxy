import Foundation
import Network

/// Latency probes for the servers list and the Test Connection button.
///
/// Two measurements exist, mirroring what V2Box shows:
/// - `measure(host:port:)` is the TCP connect time straight to the server (the "ping" next to each
///   node). The connection is opened with `preferNoProxies`: while a carrier profile is installed
///   the APN proxy is 127.0.0.1:<port>, and a plain `NWConnection` honours it, reaches the app's
///   own listener in a millisecond and reports a dead server as "2 ms". Refused, unreachable and
///   timed-out connects all come back as nil, which the UI shows as "timeout".
/// - `realDelay(url:)` asks the running sing-box core (Clash API) to fetch a URL through the proxy
///   outbound and returns that round trip. It is the only number that proves the server forwards
///   traffic: a dead or blocked server fails it even when its TCP port still answers.
enum LatencyTester {
    /// Outcome of a URL test run by the sing-box core.
    enum CoreDelay: Equatable {
        /// Round trip in milliseconds through the outbound.
        case delay(Int)
        /// The core answered but the request did not complete (dead server, wrong credentials,
        /// blocked transport).
        case unreachable
        /// The core is not running (or its API did not answer), so nothing could be measured.
        case unavailable
    }

    static let defaultTimeout: TimeInterval = 5
    /// URL the core fetches for `realDelay`; answers 204 with no body.
    static let defaultTestURL = "https://www.gstatic.com/generate_204"

    private static let queue = DispatchQueue(label: "com.slproxy.app.latency", qos: .userInitiated)

    /// POSIX failures that mean the server cannot be reached right now. `NWConnection` reports
    /// them as `.waiting` and would otherwise retry quietly until the timeout.
    private static let fatalWaitingCodes: Set<POSIXErrorCode> = [
        .ECONNREFUSED, .ECONNRESET, .EHOSTUNREACH, .EHOSTDOWN, .ENETUNREACH, .ENETDOWN, .ETIMEDOUT,
    ]

    /// TCP connect time to `host:port` in milliseconds, or nil when the connection failed or did
    /// not complete within `timeout`. Never routed through a system proxy.
    static func measure(host: String, port: Int, timeout: TimeInterval = defaultTimeout) async -> Int? {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, port > 0, port <= 65535, let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return nil
        }
        let parameters = NWParameters.tcp
        parameters.preferNoProxies = true
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.connectionTimeout = max(1, Int(timeout.rounded(.up)))
            tcp.noDelay = true
        }

        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
            let started = DispatchTime.now()
            var finished = false

            func finish(_ value: Int?) {
                guard !finished else { return }
                finished = true
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(returning: value)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let elapsed = DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds
                    finish(max(1, Int(elapsed / 1_000_000)))
                case .failed, .cancelled:
                    finish(nil)
                case .waiting(let error):
                    // Refused / unreachable: report the dead server now instead of sitting out
                    // the whole timeout while NWConnection waits for a network change.
                    if case .posix(let code) = error, fatalWaitingCodes.contains(code) {
                        finish(nil)
                    }
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
            connection.start(queue: queue)
        }
    }

    /// URL test through the running core: the Clash API fetches `url` via the outbound `tag` and
    /// reports the round trip. `.unavailable` while the engine is stopped (the passthrough holds the
    /// port but has no API) or the tag is not in the running config; `.unreachable` when the core
    /// answered but the request through the server failed or timed out.
    static func realDelay(outbound tag: String = SingBoxConfigBuilder.proxyTag,
                          url: String = defaultTestURL,
                          timeout: TimeInterval = defaultTimeout) async -> CoreDelay {
        let escapedTag = tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? tag
        guard var components = URLComponents(string: "http://\(AppGroup.clashAPIAddress)/proxies/\(escapedTag)/delay") else {
            return .unavailable
        }
        components.queryItems = [
            URLQueryItem(name: "timeout", value: String(Int(timeout * 1000))),
            URLQueryItem(name: "url", value: url),
        ]
        guard let requestURL = components.url else { return .unavailable }
        var request = URLRequest(url: requestURL)
        request.timeoutInterval = timeout + 3

        do {
            let (data, response) = try await directSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unavailable }
            switch http.statusCode {
            case 200:
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let delay = (object["delay"] as? NSNumber)?.intValue, delay > 0 {
                    return .delay(delay)
                }
                return .unreachable
            case 404:
                // No outbound with that tag in the running config.
                return .unavailable
            default:
                // 503 "an error occurred in the delay test", 504 "timeout".
                return .unreachable
            }
        } catch {
            return .unavailable
        }
    }

    /// Session with proxies disabled: the Clash API lives on loopback, and with the carrier profile
    /// installed the system proxy would route the request into the proxy listener itself.
    private static let directSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = defaultTimeout + 3
        return URLSession(configuration: configuration)
    }()

    // MARK: - Real proxy handshake (SOCKS5 / HTTP)

    /// Full round trip through a SOCKS5 or HTTP proxy, in milliseconds: TCP connect, authentication
    /// with the node's credentials, a CONNECT to `www.gstatic.com:80` and a `GET /generate_204`
    /// through the tunnel. Nil when any step fails (bad or expired credentials, refused CONNECT, no
    /// answer), so a dead server reads "timeout" like in V2Box.
    static func proxyRoundTrip(node: ProxyNode, timeout: TimeInterval = 8) async -> Int? {
        guard node.kind == .socks || node.kind == .http else { return nil }
        return await withTaskGroup(of: Int?.self) { group in
            group.addTask { try? await ProxyProbe.run(node: node, timeout: timeout) }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout + 1))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// One-shot proxy handshake over `NWConnection` (see `LatencyTester.proxyRoundTrip`).
private enum ProxyProbe {
    struct Failure: Error {}

    private static let testHost = "www.gstatic.com"
    private static let queue = DispatchQueue(label: "com.slproxy.app.probe", qos: .userInitiated)

    static func run(node: ProxyNode, timeout: TimeInterval) async throws -> Int {
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: node.port)) else { throw Failure() }
        let parameters = NWParameters.tcp
        parameters.preferNoProxies = true
        let connection = NWConnection(host: NWEndpoint.Host(node.server), port: port, using: parameters)
        // Guarantees every pending read finishes: cancelling the connection fails them.
        queue.asyncAfter(deadline: .now() + timeout) { connection.cancel() }
        defer { connection.cancel() }

        let started = DispatchTime.now()
        try await start(connection)

        if node.kind == .socks {
            try await socks5Connect(connection, node: node)
        } else {
            try await httpConnect(connection, node: node)
        }

        let request = "GET /generate_204 HTTP/1.1\r\nHost: \(testHost)\r\nConnection: close\r\n\r\n"
        try await send(connection, Data(request.utf8))
        let reply = try await receive(connection, max: 256)
        guard let head = String(data: reply, encoding: .utf8), head.hasPrefix("HTTP/1."),
              let code = Int(head.split(separator: " ").dropFirst().first ?? ""),
              (200..<400).contains(code) else { throw Failure() }

        let elapsed = DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds
        return max(1, Int(elapsed / 1_000_000))
    }

    // MARK: Protocol steps

    private static func socks5Connect(_ connection: NWConnection, node: ProxyNode) async throws {
        let username = node.username ?? ""
        let password = node.password ?? ""
        let hasLogin = !username.isEmpty
        try await send(connection, Data(hasLogin ? [0x05, 0x02, 0x00, 0x02] : [0x05, 0x01, 0x00]))
        let method = try await receiveExactly(connection, 2)
        guard method[0] == 0x05 else { throw Failure() }
        switch method[1] {
        case 0x00:
            break
        case 0x02:
            let user = Array(username.utf8), pass = Array(password.utf8)
            guard hasLogin, user.count < 256, pass.count < 256 else { throw Failure() }
            try await send(connection, Data([0x01, UInt8(user.count)] + user + [UInt8(pass.count)] + pass))
            let auth = try await receiveExactly(connection, 2)
            guard auth[1] == 0x00 else { throw Failure() } // Wrong or expired credentials.
        default:
            throw Failure() // 0xFF: no acceptable method.
        }

        let host = Array(testHost.utf8)
        try await send(connection, Data([0x05, 0x01, 0x00, 0x03, UInt8(host.count)] + host + [0x00, 0x50]))
        let head = try await receiveExactly(connection, 4)
        guard head[0] == 0x05, head[1] == 0x00 else { throw Failure() }
        switch head[3] {
        case 0x01: _ = try await receiveExactly(connection, 4 + 2)
        case 0x04: _ = try await receiveExactly(connection, 16 + 2)
        case 0x03:
            let length = try await receiveExactly(connection, 1)
            _ = try await receiveExactly(connection, Int(length[0]) + 2)
        default: throw Failure()
        }
    }

    private static func httpConnect(_ connection: NWConnection, node: ProxyNode) async throws {
        var request = "CONNECT \(testHost):80 HTTP/1.1\r\nHost: \(testHost):80\r\n"
        if let username = node.username, !username.isEmpty {
            let token = Data("\(username):\(node.password ?? "")".utf8).base64EncodedString()
            request += "Proxy-Authorization: Basic \(token)\r\n"
        }
        request += "\r\n"
        try await send(connection, Data(request.utf8))
        let reply = try await receive(connection, max: 512)
        guard let head = String(data: reply, encoding: .utf8), head.hasPrefix("HTTP/1."),
              head.split(separator: " ").dropFirst().first == "200" else { throw Failure() }
    }

    // MARK: NWConnection as async calls

    private static func start(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var finished = false
            connection.stateUpdateHandler = { state in
                guard !finished else { return }
                switch state {
                case .ready:
                    finished = true
                    continuation.resume()
                case .failed, .cancelled:
                    finished = true
                    continuation.resume(throwing: Failure())
                case .waiting(let error):
                    if case .posix = error {
                        finished = true
                        continuation.resume(throwing: Failure())
                    }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private static func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private static func receive(_ connection: NWConnection, max: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: Failure())
                }
            }
        }
    }

    private static func receiveExactly(_ connection: NWConnection, _ count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, data.count == count {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: Failure())
                }
            }
        }
    }
}
