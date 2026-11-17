import Foundation

/// Where the SailorsLoot backend lives. HTTPS only; certificate validation is the standard iOS
/// one (no pinning, WordPress renews the certificate automatically).
enum SLConfig {
    static let apiBase = URL(string: "https://sailorsloot.xyz/wp-json/sl-proxy/v1/")!
    static let topUpURL = URL(string: "https://sailorsloot.xyz")!
    /// Opened by "Sign up" on the signed-out Proxies screen. Change it here if the registration page lives elsewhere.
    static let signUpURL = URL(string: "https://sailorsloot.xyz/register/")!
}

enum SLAPIError: LocalizedError {
    /// 401: no token, expired token or revoked token. The app asks the user to log in again.
    case unauthorized
    case server(message: String, status: Int)
    case network
    case decoding

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Please log in to your SailorsLoot account again."
        case .server(let message, _): return message
        case .network: return "Could not reach SailorsLoot. Check your connection and try again."
        case .decoding: return "SailorsLoot sent a reply the app could not read."
        }
    }
}

// MARK: - Models (snake_case JSON, decoded with convertFromSnakeCase)

struct SLLoginReply: Decodable {
    let token: String
    let username: String
    let displayName: String
    let balance: Double
}

struct SLBalanceReply: Decodable {
    let balance: Double
    let username: String
    let displayName: String
    let activeProxies: Int
}

struct SLListing: Decodable, Identifiable, Hashable {
    let id: Int
    let ipMasked: String
    let countryCode: String
    let flag: String
    let state: String
    let city: String
    let zip: String
    let isp: String
    let type: String
    let speed: String
    let pingMs: Int?
    let status: String
    let price: Double
}

struct SLListingPage: Decodable {
    let items: [SLListing]
    let page: Int
    let totalPages: Int
    let total: Int
}

struct SLFilterOptions: Decodable, Equatable {
    var countries: [String] = []
    var states: [String] = []
    var cities: [String] = []
    var isps: [String] = []
}

/// Real SOCKS5 credentials of a purchased proxy (purchase reply and 24H history item).
struct SLPurchased: Decodable, Identifiable, Hashable {
    var id: String { username }
    let host: String
    let port: Int
    let username: String
    let password: String
    let ipMasked: String
    let country: String
    let city: String
    let isp: String
    let expiresAt: Date
    var balance: Double?
}

struct SLHistoryReply: Decodable {
    let items: [SLPurchased]
}

private struct SLErrorBody: Decodable {
    let message: String?
}

// MARK: - Client

/// All SailorsLoot API calls. The Bearer token comes from the Keychain on every request.
final class SLAPIClient {
    static let shared = SLAPIClient()

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let iso = ISO8601DateFormatter()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = iso.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date"))
        }
        return decoder
    }()

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], authenticated: Bool = true) async throws -> T {
        try await send(path, method: "GET", query: query, body: nil, authenticated: authenticated, timeout: 20)
    }

    func post<T: Decodable>(_ path: String, body: [String: Any], authenticated: Bool = true,
                            timeout: TimeInterval = 20) async throws -> T {
        try await send(path, method: "POST", query: [], body: body, authenticated: authenticated, timeout: timeout)
    }

    private func send<T: Decodable>(_ path: String, method: String, query: [URLQueryItem],
                                    body: [String: Any]?, authenticated: Bool,
                                    timeout: TimeInterval) async throws -> T {
        guard var components = URLComponents(url: SLConfig.apiBase.appendingPathComponent(path),
                                             resolvingAgainstBaseURL: false) else { throw SLAPIError.network }
        components.scheme = "https" // Never plain HTTP, whatever the base URL says.
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url, url.scheme == "https" else { throw SLAPIError.network }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authenticated {
            guard let token = KeychainManager.get(KeychainManager.Key.token) else { throw SLAPIError.unauthorized }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            // Some hosts strip Authorization; the server also reads this header.
            request.setValue(token, forHTTPHeaderField: "X-SL-Token")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SLAPIError.network
        }
        guard let http = response as? HTTPURLResponse else { throw SLAPIError.network }
        if http.statusCode == 401 && authenticated { throw SLAPIError.unauthorized }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? decoder.decode(SLErrorBody.self, from: data))?.message
            throw SLAPIError.server(message: message ?? "SailorsLoot answered with HTTP \(http.statusCode).",
                                    status: http.statusCode)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw SLAPIError.decoding
        }
    }
}
