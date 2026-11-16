import Foundation

/// The SailorsLoot proxy market: live list with search and filters, one-tap purchase and the 24H
/// list of purchased proxies. A purchase is saved into the Configs store, selected, and connected.
@MainActor
final class ProxyMarketStore: ObservableObject {
    struct Filter: Equatable {
        var country = ""
        var state = ""
        var city = ""
        var zip = ""
        var isp = ""

        var activeCount: Int {
            [country, state, city, zip, isp].filter { !$0.isEmpty }.count
        }
    }

    @Published var query = ""
    @Published var filter = Filter()
    @Published private(set) var items: [SLListing] = []
    @Published private(set) var total = 0
    @Published private(set) var isLoading = false
    @Published private(set) var options = SLFilterOptions()
    @Published private(set) var history: [SLPurchased] = []
    @Published private(set) var isLoadingHistory = false
    @Published private(set) var buyingID: Int?
    @Published var errorMessage: String?

    private var page = 1
    private var totalPages = 1
    private let api = SLAPIClient.shared
    private let account: SLAccountStore
    private let nodes: NodeStore
    private let tunnel: TunnelController

    init(account: SLAccountStore, nodes: NodeStore, tunnel: TunnelController) {
        self.account = account
        self.nodes = nodes
        self.tunnel = tunnel
    }

    // MARK: - Live list

    func reload() async {
        guard account.isLoggedIn else {
            items = []
            total = 0
            return
        }
        page = 1
        await fetch(reset: true)
    }

    /// Infinite scroll: loads the next page when the last card shows up.
    func loadMoreIfNeeded(current item: SLListing) async {
        guard let last = items.last, last.id == item.id, page < totalPages, !isLoading else { return }
        page += 1
        await fetch(reset: false)
    }

    private func fetch(reset: Bool) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        var parameters = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per_page", value: "20"),
        ]
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { parameters.append(URLQueryItem(name: "q", value: text)) }
        for (name, value) in [("country", filter.country), ("state", filter.state), ("city", filter.city),
                              ("zip", filter.zip), ("isp", filter.isp)] where !value.isEmpty {
            parameters.append(URLQueryItem(name: name, value: value))
        }
        do {
            let reply: SLListingPage = try await api.get("proxies", query: parameters)
            items = reset ? reply.items : items + reply.items
            total = reply.total
            page = reply.page
            totalPages = reply.totalPages
        } catch {
            if !reset { page = max(1, page - 1) }
            account.handle(error)
            errorMessage = error.localizedDescription
        }
    }

    /// Values for the filter sheet, narrowed by the chosen country / state.
    func loadOptions(country: String = "", state: String = "") async {
        guard account.isLoggedIn else { return }
        var parameters: [URLQueryItem] = []
        if !country.isEmpty { parameters.append(URLQueryItem(name: "country", value: country)) }
        if !state.isEmpty { parameters.append(URLQueryItem(name: "state", value: state)) }
        do {
            options = try await api.get("proxies/filters", query: parameters)
        } catch {
            account.handle(error)
        }
    }

    // MARK: - 24H list

    func loadHistory() async {
        guard account.isLoggedIn else {
            history = []
            return
        }
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        do {
            let reply: SLHistoryReply = try await api.get("proxies/history")
            history = reply.items
        } catch {
            account.handle(error)
        }
    }

    // MARK: - Buy and connect

    /// Buys `listing`, saves the returned SOCKS5 login into Configs, selects it and connects.
    /// Returns the purchase, or nil with `errorMessage` set when nothing was bought.
    func buy(_ listing: SLListing) async -> SLPurchased? {
        buyingID = listing.id
        errorMessage = nil
        defer { buyingID = nil }
        do {
            // The server verifies the IP is live before charging, which can take about a minute.
            let purchase: SLPurchased = try await api.post(
                "proxies/purchase", body: ["proxy_id": listing.id], timeout: 120
            )
            if let balance = purchase.balance { account.updateBalance(balance) }
            let place = listing.city.isEmpty ? listing.countryCode : listing.city
            connect(purchase, name: "\(place) \(listing.flag)")
            await loadHistory()
            return purchase
        } catch {
            account.handle(error)
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Adds the purchase to Configs (once), makes it the active server and connects when idle.
    func connect(_ purchase: SLPurchased, name: String? = nil) {
        guard purchase.expiresAt > Date() else {
            nodes.toast = "That proxy has expired"
            return
        }
        let fallback = purchase.city.isEmpty ? purchase.country : purchase.city
        let label = name ?? (fallback.isEmpty ? "SailorsLoot proxy" : fallback)
        let node = nodes.addPurchased(purchase, name: label)
        nodes.select(node)
        if !tunnel.isConnected && !tunnel.isBusy { tunnel.toggle() }
        nodes.toast = "Connecting to \(node.name)"
    }
}
