import Foundation
import Network

/// Reachability probe for an imported proxy config (the Test Connection button on Home).
///
/// While the core runs, the probe is sing-box's own URL test through the proxy outbound
/// (`LatencyTester.realDelay`): the only check that proves the server forwards traffic. Otherwise a
/// TCP connection is opened straight to the server with `preferNoProxies`, so the carrier profile's
/// APN proxy (the app's own 127.0.0.1 listener) can never make a dead server look reachable.
final class ProxyPingTester {
    enum Result: Equatable {
        /// `throughProxy` is true when the number is the round trip of a URL test run by the core
        /// (proxy connected), false for a TCP connect straight to the server.
        case online(latencyMs: Int, throughProxy: Bool)
        case offline(error: String)
    }

    static let shared = ProxyPingTester()

    private let queue = DispatchQueue(label: "com.slproxy.app.ping", qos: .userInitiated)
    private let timeout: TimeInterval = 3

    /// POSIX failures reported as `.waiting` that mean the server is unreachable right now.
    private static let fatalWaitingCodes: Set<POSIXErrorCode> = [
        .ECONNREFUSED, .ECONNRESET, .EHOSTUNREACH, .EHOSTDOWN, .ENETUNREACH, .ENETDOWN, .ETIMEDOUT,
    ]

    /// Parses host/port from a share link or sing-box JSON, then probes it: through the core when
    /// it runs, directly otherwise.
    func test(config: String, completion: @escaping (Result) -> Void) {
        guard let endpoint = ProxyEndpoint.parse(config) else {
            completion(.offline(error: "Could not read a server address and port from the config"))
            return
        }
        Task {
            switch await LatencyTester.realDelay() {
            case .delay(let ms):
                await MainActor.run { completion(.online(latencyMs: ms, throughProxy: true)) }
            case .unreachable:
                await MainActor.run {
                    completion(.offline(error: "The proxy is connected, but no data came back through this server"))
                }
            case .unavailable:
                self.test(host: endpoint.host, port: endpoint.port, completion: completion)
            }
        }
    }

    /// Opens a TCP connection with NWConnection (no system proxy) and gives up after 3 seconds.
    /// The completion is always delivered on the main queue, exactly once.
    func test(host: String, port: Int, completion: @escaping (Result) -> Void) {
        guard (1...65535).contains(port), let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            completion(.offline(error: "Invalid port \(port)"))
            return
        }

        let parameters = NWParameters.tcp
        parameters.preferNoProxies = true
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.connectionTimeout = Int(timeout)
            tcp.noDelay = true
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)

        let started = DispatchTime.now()
        var finished = false
        let finish: (Result) -> Void = { result in
            guard !finished else { return }
            finished = true
            connection.stateUpdateHandler = nil
            connection.cancel()
            DispatchQueue.main.async { completion(result) }
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let elapsed = DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds
                finish(.online(latencyMs: max(1, Int(elapsed / 1_000_000)), throughProxy: false))
            case .failed(let error):
                finish(.offline(error: Self.describe(error)))
            case .waiting(let error):
                // Refused or no route: do not sit out the full timeout.
                if case .posix(let code) = error, Self.fatalWaitingCodes.contains(code) {
                    finish(.offline(error: Self.describe(error)))
                }
            case .cancelled:
                finish(.offline(error: "Cancelled"))
            default:
                break
            }
        }

        queue.asyncAfter(deadline: .now() + timeout) { [timeout] in
            finish(.offline(error: "No response within \(Int(timeout)) s"))
        }
        connection.start(queue: queue)
    }

    /// async/await wrapper around the completion-based API.
    func test(config: String) async -> Result {
        await withCheckedContinuation { continuation in
            test(config: config) { continuation.resume(returning: $0) }
        }
    }

    private static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: return "Connection refused (port closed)"
            case .ECONNRESET: return "Connection reset by the server"
            case .ETIMEDOUT: return "Connection timed out"
            case .EHOSTUNREACH, .EHOSTDOWN, .ENETUNREACH: return "Host unreachable"
            case .ENETDOWN: return "No network connection"
            default: return String(cString: strerror(code.rawValue))
            }
        case .dns: return "DNS lookup failed"
        case .tls: return "TLS handshake failed"
        @unknown default: return error.localizedDescription
        }
    }
}
