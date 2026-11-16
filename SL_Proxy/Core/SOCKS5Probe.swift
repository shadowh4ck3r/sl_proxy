import Foundation
import Network

/// Accurate ping for SOCKS5 and HTTP proxy servers, the way V2Box does it.
///
/// Why this exists: a plain TCP connect to the proxy host succeeds even when the account behind
/// it is dead. 9Proxy / niceproxy.io style gateways accept the TCP connection from anyone, so an
/// expired 6h or 24h session still "pinged" with a number. The probe goes the whole way instead:
///
///   1. TCP connect to the proxy
///   2. SOCKS5 greeting and username/password login (HTTP proxies: `CONNECT` with Proxy-Authorization)
///   3. Ask the proxy to open a tunnel to a well-known host
///   4. Send a tiny HTTP request through the tunnel and require an HTTP answer
///
/// Only if every step succeeds does it report milliseconds (the full round trip). A refused login,
/// an expired session, a dead exit IP, a closed tunnel or a silent timeout all come back as nil,
/// which the UI shows as "timeout".
enum ProxyProbe {
    struct Target {
        var host: String
        var port: Int
        var username: String?
        var password: String?
        var isHTTP: Bool
    }

    /// Round trip through the proxy in milliseconds, or nil when the proxy does not really work.
    static func measure(_ target: Target, timeout: TimeInterval = 7) async -> Int? {
        let probe = Session(target: target)
        return await probe.run(timeout: timeout)
    }

    // The tunnel destination: Google's connectivity check answers 204 on port 80 from anywhere.
    private static let testHost = "connectivitycheck.gstatic.com"
    private static let testRequest = "GET /generate_204 HTTP/1.1\r\nHost: \(testHost)\r\nConnection: close\r\nUser-Agent: SL_Proxy\r\n\r\n"

    // MARK: - One probe run

    private final class Session: @unchecked Sendable {
        let target: Target
        private let queue = DispatchQueue(label: "sl.proxyprobe")
        private var connection: NWConnection?
        private var continuation: CheckedContinuation<Int?, Never>?
        private var finished = false
        private var started = Date()

        init(target: Target) { self.target = target }

        func run(timeout: TimeInterval) async -> Int? {
            guard let port = NWEndpoint.Port(rawValue: UInt16(truncatingIfNeeded: target.port)), !target.host.isEmpty else {
                return nil
            }
            return await withCheckedContinuation { (continuation: CheckedContinuation<Int?, Never>) in
                queue.async {
                    self.continuation = continuation
                    self.started = Date()
                    let parameters = NWParameters.tcp
                    // Ping the server itself, never through the carrier profile's local proxy.
                    parameters.preferNoProxies = true
                    let connection = NWConnection(host: NWEndpoint.Host(self.target.host), port: port, using: parameters)
                    self.connection = connection
                    connection.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .ready: self.handshake()
                        case .failed, .cancelled: self.finish(nil)
                        case .waiting: self.finish(nil)   // unreachable right now: report, do not hang
                        default: break
                        }
                    }
                    connection.start(queue: self.queue)
                    self.queue.asyncAfter(deadline: .now() + timeout) { self.finish(nil) }
                }
            }
        }

        private func finish(_ result: Int?) {
            guard !finished else { return }
            finished = true
            connection?.cancel()
            connection = nil
            continuation?.resume(returning: result)
            continuation = nil
        }

        private func succeed() {
            finish(Int((Date().timeIntervalSince(started) * 1000).rounded()))
        }

        // MARK: Steps

        private func handshake() {
            target.isHTTP ? httpConnect() : socksGreeting()
        }

        private func send(_ data: Data, then next: @escaping () -> Void) {
            connection?.send(content: data, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.finish(nil) } else { next() }
            })
        }

        private func receive(min: Int, max: Int = 512, _ handler: @escaping ([UInt8]) -> Void) {
            connection?.receive(minimumIncompleteLength: min, maximumLength: max) { [weak self] data, _, _, error in
                guard let self, error == nil, let data, data.count >= min else { self?.finish(nil); return }
                handler(Array(data))
            }
        }

        // SOCKS5 (RFC 1928 / 1929)

        private func socksGreeting() {
            let hasLogin = !(target.username ?? "").isEmpty
            let methods: [UInt8] = hasLogin ? [0x00, 0x02] : [0x00]
            send(Data([0x05, UInt8(methods.count)] + methods)) { [self] in
                receive(min: 2) { [self] reply in
                    guard reply[0] == 0x05 else { return finish(nil) }
                    switch reply[1] {
                    case 0x00: socksConnect()
                    case 0x02 where hasLogin: socksLogin()
                    default: finish(nil) // 0xFF: no acceptable method
                    }
                }
            }
        }

        private func socksLogin() {
            let user = Array((target.username ?? "").utf8)
            let pass = Array((target.password ?? "").utf8)
            guard user.count <= 255, pass.count <= 255 else { return finish(nil) }
            send(Data([0x01, UInt8(user.count)] + user + [UInt8(pass.count)] + pass)) { [self] in
                receive(min: 2) { [self] reply in
                    // Wrong password, expired or revoked session: status != 0.
                    reply[1] == 0x00 ? socksConnect() : finish(nil)
                }
            }
        }

        private func socksConnect() {
            let host = Array(ProxyProbe.testHost.utf8)
            let request: [UInt8] = [0x05, 0x01, 0x00, 0x03, UInt8(host.count)] + host + [0x00, 0x50] // port 80
            send(Data(request)) { [self] in
                receive(min: 4) { [self] reply in
                    // reply[1] == 0 means the exit really opened the tunnel; anything else is dead.
                    guard reply[0] == 0x05, reply[1] == 0x00 else { return finish(nil) }
                    sendTestRequest()
                }
            }
        }

        // HTTP proxy

        private func httpConnect() {
            var request = "CONNECT \(ProxyProbe.testHost):80 HTTP/1.1\r\nHost: \(ProxyProbe.testHost):80\r\n"
            if let user = target.username, !user.isEmpty {
                let token = Data("\(user):\(target.password ?? "")".utf8).base64EncodedString()
                request += "Proxy-Authorization: Basic \(token)\r\n"
            }
            request += "\r\n"
            send(Data(request.utf8)) { [self] in
                receive(min: 12) { [self] reply in
                    let head = String(decoding: reply.prefix(16), as: UTF8.self)
                    head.contains(" 200") ? sendTestRequest() : finish(nil)
                }
            }
        }

        // Through the tunnel

        private func sendTestRequest() {
            send(Data(ProxyProbe.testRequest.utf8)) { [self] in
                receive(min: 5) { [self] reply in
                    String(decoding: reply.prefix(5), as: UTF8.self) == "HTTP/" ? succeed() : finish(nil)
                }
            }
        }
    }
}
