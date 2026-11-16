import Foundation

/// One row of the live proxy list. The server only ever sends a masked IP here: no real IP, port,
/// username or password exists in this type, so there is nothing to leak from the list.
struct MarketProxy: Codable, Identifiable, Hashable {
    let id: Int
    let countryCode: String
    let country: String
    let flag: String
    let ipMasked: String
    let state: String
    let city: String
    let zip: String
    let isp: String
    let type: String?
    let pingMs: Int?
    let status: String?
    let price: Double
    let currency: String?

    var pingText: String { pingMs.map { "\($0)ms" } ?? "-" }
}

struct MarketPage: Codable {
    let items: [MarketProxy]
    let page: Int
    let perPage: Int
    let total: Int
    let totalPages: Int
}

struct MarketFacets: Codable, Equatable {
    struct Country: Codable, Hashable, Identifiable {
        let code: String
        let name: String
        let flag: String
        var id: String { code }
    }
    let countries: [Country]
    let states: [String]
    let cities: [String]
    let isps: [String]
}

/// Real SOCKS5 credentials, returned by the server only after a successful purchase (or from the
/// last-24h history of the signed-in user). Kept in memory; the Configs store holds the saved copy.
struct PurchasedProxy: Codable, Identifiable, Hashable {
    let purchaseId: Int
    let proxyId: Int
    let type: String
    let host: String
    let port: Int
    let username: String
    let password: String
    let ip: String?
    let city: String?
    let country: String?
    let isp: String?
    let expiresAt: Date
    let remainingSeconds: Int?
    let balance: Double?
    let alreadyOwned: Bool?
    let label: String?
    let purchasedAt: Date?

    var id: Int { purchaseId }

    var title: String {
        if let label, !label.isEmpty { return label }
        let parts = [city, country].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? "SL Proxy #\(purchaseId)" : parts.joined(separator: ", ")
    }
}

struct PurchaseHistory: Codable {
    let items: [PurchasedProxy]
    let balance: Double?
}

struct LoginReply: Codable {
    let token: String
    let expiresAt: Date?
    let username: String
    let displayName: String?
    let balance: Double
}

struct BalanceReply: Codable {
    struct Account: Codable {
        let username: String
        let displayName: String?
        let memberSince: String?
        let activeProxies: Int?
    }
    let balance: Double
    let account: Account?
}

enum NairaFormat {
    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.locale = Locale(identifier: "en_NG")
        return formatter
    }()

    /// "₦ 514.03"
    static func string(_ value: Double) -> String {
        "₦ " + (formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value))
    }
}
