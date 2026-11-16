import Foundation

/// State behind the Proxy List and 24H List: search, filters, paging, purchase and history.
@MainActor
final class MarketStore: ObservableObject {
    struct Filters: Equatable {
        var country = ""      // ISO code, e.g. "US"
        var state = ""
        var city = ""
        var zip = ""
        var isp = ""

        var activeCount: Int { [country, state, city, zip, isp].filter { !$0.isEmpty }.count }
    }

    @Published var query = ""
    @Published var filters = Filters()
    @Published private(set) var items: [MarketProxy] = []
    @Published private(set) var total = 0
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var facets: MarketFacets?
    @Published private(set) var history: [PurchasedProxy] = []
    @Published private(set) var historyLoading = false

    private let account = AccountStore.shared
    private let api = SLAPIClient.shared
    private var page = 1
    private var totalPages = 1
    private let perPage = 20
    private var generation = 0

    var hasMore: Bool { page < totalPages }

    // MARK: - List

    /// Reloads page 1 for the current search text and filters. Stale replies are dropped.
    func reload() async {
        guard account.isLoggedIn else { return }
        generation += 1
        let mine = generation
        isLoading = true
        errorMessage = nil
        defer { if mine == generation { isLoading = false } }
        do {
            let result: MarketPage = try await api.get("/proxies", query: queryItems(page: 1))
            guard mine == generation else { return }
            items = result.items
            total = result.total
            page = result.page
            totalPages = result.totalPages
        } catch let error as SLAPIError {
            report(error, generation: mine)
        } catch {}
    }

    func loadMore(after item: MarketProxy) async {
        guard hasMore, !isLoading, item.id == items.last?.id else { return }
        generation += 1
        let mine = generation
        isLoading = true
        defer { if mine == generation { isLoading = false } }
        do {
            let result: MarketPage = try await api.get("/proxies", query: queryItems(page: page + 1))
            guard mine == generation else { return }
            let known = Set(items.map(\.id))
            items.append(contentsOf: result.items.filter { !known.contains($0.id) })
            total = result.total
            page = result.page
            totalPages = result.totalPages
        } catch let error as SLAPIError {
            report(error, generation: mine)
        } catch {}
    }

    func loadFacets() async {
        guard account.isLoggedIn, facets == nil else { return }
        facets = try? await api.get("/proxies/filters")
    }

    private func queryItems(page: Int) -> [String: String] {
        [
            "q": query.trimmingCharacters(in: .whitespacesAndNewlines),
            "country": filters.country,
            "state": filters.state,
            "city": filters.city,
            "zip": filters.zip,
            "isp": filters.isp,
            "page": String(page),
            "per_page": String(perPage),
        ]
    }

    private func report(_ error: SLAPIError, generation mine: Int) {
        guard mine == generation, error != .unauthorized else { return } // 401 is handled by AccountStore
        errorMessage = error.localizedDescription
    }

    // MARK: - 24H list

    func loadHistory() async {
        guard account.isLoggedIn else { return }
        historyLoading = true
        defer { historyLoading = false }
        do {
            let result: PurchaseHistory = try await api.get("/proxies/history")
            history = result.items.filter { $0.expiresAt > Date() }
            account.updateBalance(result.balance)
        } catch let error as SLAPIError {
            if error != .unauthorized { errorMessage = error.localizedDescription }
        } catch {}
    }

    /// Drops expired entries locally; the countdown view calls this when a timer reaches zero.
    func pruneExpired() {
        let alive = history.filter { $0.expiresAt > Date() }
        if alive.count != history.count { history = alive }
    }

    // MARK: - Purchase

    /// Server side: balance check, live IP check, atomic debit, 24h log. Returns the real credentials.
    func purchase(_ proxy: MarketProxy) async throws -> PurchasedProxy {
        let result: PurchasedProxy = try await api.post("/proxies/purchase", body: ["proxy_id": proxy.id])
        account.updateBalance(result.balance)
        if let index = history.firstIndex(where: { $0.purchaseId == result.purchaseId }) {
            history[index] = result
        } else {
            history.insert(result, at: 0)
        }
        return result
    }
}
