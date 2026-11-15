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
}
