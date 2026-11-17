import SwiftUI

/// 9proxy-style dashboard: wallet badge and refresh on top, then Proxy List (search, filters,
/// cards, tap to buy) and 24H List (purchased proxies with a countdown and one-tap Connect).
struct MarketView: View {
    private enum Segment: String, CaseIterable, Identifiable {
        case list = "Proxy List"
        case day = "24H List"
        var id: String { rawValue }
    }

    @EnvironmentObject private var account: SLAccountStore
    @EnvironmentObject private var market: ProxyMarketStore
    @EnvironmentObject private var nodes: NodeStore
    @State private var segment: Segment = .list
    @State private var selected: SLListing?
    @State private var showFilters = false
    @State private var showAccount = false
    @State private var showSignUp = false

    var body: some View {
        NavigationStack {
            ZStack {
                if account.isLoggedIn {
                    Brand.background
                } else {
                    SignedOutBackground()
                }
                VStack(spacing: 12) {
                    header
                    Picker("View", selection: $segment) {
                        ForEach(Segment.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)

                    if !account.isLoggedIn {
                        loggedOut
                    } else if segment == .list {
                        listPane
                    } else {
                        historyPane
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $selected) { PurchaseSheet(listing: $0) }
            .sheet(isPresented: $showFilters) { MarketFilterSheet() }
            .sheet(isPresented: $showAccount) { AccountView() }
            .sheet(isPresented: $showSignUp) { SafariView(url: SLConfig.signUpURL).ignoresSafeArea() }
            // A 401 anywhere in the market flow asks the user to log in again.
            .sheet(isPresented: $account.needsLogin) { AccountView() }
            .task { await refreshAll() }
            .onChange(of: account.isLoggedIn) { _ in Task { await refreshAll() } }
        }
    }

    private func refreshAll() async {
        guard account.isLoggedIn else { return }
        await account.refreshBalance()
        await market.reload()
        await market.loadHistory()
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Proxies")
                    .font(.title2.weight(.bold))
                Text(account.username.map { "@\($0)" } ?? "Not signed in")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showAccount = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "creditcard.fill").font(.caption)
                    Text(account.balanceText)
                        .font(.subheadline.monospacedDigit().weight(.bold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Brand.gold.opacity(0.18), in: Capsule())
                .overlay(Capsule().strokeBorder(Brand.gradient, lineWidth: 1).opacity(0.6))
            }
            .buttonStyle(.plain)
            Button {
                Task { await refreshAll() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.body.weight(.semibold))
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!account.isLoggedIn)
            .accessibilityLabel("Refresh")
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    // MARK: Signed out

    private var loggedOut: some View {
        SignedOutProxiesView(
            onConnect: { showAccount = true },
            onSignUp: { showSignUp = true }
        )
    }

    // MARK: Proxy List

    private var listPane: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search IP / City / ZIP / ISP", text: $market.query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { Task { await market.reload() } }
                    if !market.query.isEmpty {
                        Button {
                            market.query = ""
                            Task { await market.reload() }
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Button {
                    showFilters = true
                } label: {
                    Image(systemName: market.filter.activeCount > 0
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                        .font(.title2)
                        .foregroundStyle(market.filter.activeCount > 0 ? Brand.orange : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Filters")
            }
            .padding(.horizontal)

            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(market.items) { item in
                        MarketProxyCard(listing: item)
                            .onTapGesture { selected = item }
                            .task { await market.loadMoreIfNeeded(current: item) }
                    }
                    if market.isLoading {
                        ProgressView().padding()
                    } else if market.items.isEmpty {
                        Text(market.errorMessage ?? "No live proxies match your search.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 40)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .refreshable { await market.reload() }
        }
    }

    // MARK: 24H List

    private var historyPane: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(market.history) { purchase in
                    PurchasedProxyCard(
                        purchase: purchase,
                        isActive: nodes.activeNode?.username == purchase.username
                    ) {
                        market.connect(purchase)
                    }
                }
                if market.isLoadingHistory && market.history.isEmpty {
                    ProgressView().padding()
                } else if market.history.isEmpty {
                    Text("Proxies you buy stay here until they expire, so you can reconnect without paying again.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 40)
                        .padding(.horizontal, 24)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .refreshable { await market.loadHistory() }
    }
}
