import Foundation

extension Notification.Name {
    /// Posted when the server answers 401 (token revoked or expired). `AccountStore` listens,
    /// clears the Keychain and asks the user to sign in again.
    static let slSessionExpired = Notification.Name("slapp.sessionExpired")
}

enum SLAPIError: LocalizedError, Equatable {
    case unauthorized
    case insecureURL
    case server(status: Int, message: String)
    case network(String)
    case decoding

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Your session ended. Sign in again."
        case .insecureURL: return "Blocked: the request was not HTTPS to sailorsloot.xyz."
        case .server(_, let message): return message
        case .network(let message): return message
        case .decoding: return "Unexpected reply from the server."
        }
    }
}

/// Thin HTTPS client for `https://sailorsloot.xyz/wp-json/sl-proxy/v1`.
///
/// - Only `https` URLs on `sailorsloot.xyz` are ever requested; redirects to anything else are refused.
/// - Standard iOS TLS validation through `URLSession` (App Transport Security stays on, TLS 1.2+,
///   no certificate pinning, so WordPress certificate renewals never break the app).
/// - The Bearer token is read from the Keychain per request. A 401 clears the session.
/// - Ephemeral session: no cookies, no URL cache, so balances and credentials are not written to disk.
final class SLAPIClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = SLAPIClient()

    static let host = "sailorsloot.xyz"
    private static let base = "https://\(host)/wp-json/sl-proxy/v1"

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 25
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    // MARK: - Public

    func get<T: Decodable>(_ path: String, query: [String: String] = [:], authenticated: Bool = true) async throws -> T {
        try await send(path, method: "GET", query: query, body: nil, authenticated: authenticated)
    }

    func post<T: Decodable>(_ path: String, body: [String: Any], authenticated: Bool = true) async throws -> T {
        try await send(path, method: "POST", query: [:], body: body, authenticated: authenticated)
    }

    // MARK: - Core

    private func send<T: Decodable>(_ path: String, method: String, query: [String: String],
                                    body: [String: Any]?, authenticated: Bool) async throws -> T {
        guard var components = URLComponents(string: Self.base + path) else { throw SLAPIError.insecureURL }
        let items = query.filter { !$0.value.isEmpty }.map { URLQueryItem(name: $0.key, value: $0.value) }
        if !items.isEmpty { components.queryItems = items }
        guard let url = components.url, Self.isAllowed(url) else { throw SLAPIError.insecureURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("SL_Proxy/\(Bundle.main.shortVersion) iOS", forHTTPHeaderField: "User-Agent")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        if authenticated {
            guard let stored = KeychainManager.loadSession(), !stored.isExpired else {
                await Self.postSessionExpired()
                throw SLAPIError.unauthorized
            }
            request.setValue("Bearer \(stored.token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch {
            throw SLAPIError.network(Self.friendly(error))
        }
        guard let http = response as? HTTPURLResponse else { throw SLAPIError.decoding }

        if http.statusCode == 401, authenticated {
            await Self.postSessionExpired()
            throw SLAPIError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SLAPIError.server(status: http.statusCode, message: Self.serverMessage(data) ?? "Request failed (\(http.statusCode)).")
        }
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw SLAPIError.decoding
        }
    }

    // MARK: - Helpers

    static func isAllowed(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == host
    }

    @MainActor private static func postSessionExpired() {
        NotificationCenter.default.post(name: .slSessionExpired, object: nil)
    }

    private static func serverMessage(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["message"] as? String
    }

    private static func friendly(_ error: Error) -> String {
        guard let urlError = error as? URLError else { return error.localizedDescription }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost: return "No internet connection."
        case .timedOut: return "The server took too long to answer."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            return "Could not make a secure connection to sailorsloot.xyz."
        default: return urlError.localizedDescription
        }
    }

    /// WordPress sends ISO-8601 UTC strings ("2026-11-15T14:00:00Z").
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: string) { return date }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: string) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(string)"))
        }
        return decoder
    }()

    // MARK: - URLSessionTaskDelegate: never follow a redirect off HTTPS / off sailorsloot.xyz

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url, Self.isAllowed(url) else { return nil }
        return request
    }
}
