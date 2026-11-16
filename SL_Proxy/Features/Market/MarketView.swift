import SwiftUI

/// 9proxy-style dashboard in the SL_Proxy dark / gold look:
/// header (wallet badge + refresh), a Proxy List / 24H List switch, search + filter, and proxy cards.
/// Presented full screen from Home; closing it returns to Home where the purchased proxy connects.
struct MarketView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var nodes: NodeStore
    @EnvironmentObject private var tunnel: TunnelController
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject private var account = AccountStore.shared
    @StateObject private var market = MarketStore()

    enum Tab: String, CaseIterable, Identifiable {
        case list = "Proxy List"
        case history = "24H List"
        var id: Self { self }
    }

    @State private var tab: Tab = .list
    @State private var showFilters = false
    @State private var showTopUp = false
    @State private var selected: MarketProxy?

    private var style: NavigationStyle { settings.value.navigationStyle }

    private struct SearchKey: Equatable {
        var query: String
        var filters: MarketStore.Filters
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Brand.background
                if account.isLoggedIn {
                    VStack(spacing: 0) {
                        header
                        tabPicker
                        switch tab {
                        case .list: proxyList
                        case .history: historyList
                        }
                    }
                } else {
                    loggedOut
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(isPresented: $account.showLogin) { ConnectAccountView() }
        .sheet(isPresented: $showFilters) { FilterSheet(market: market) }
        .sheet(isPresented: $showTopUp, onDismiss: { Task { await account.refreshBalance() } }) {
            SafariView(url: SailorsLootLinks.site).ignoresSafeArea()
        }
        .sheet(item: $selected) { proxy in
            PurchaseSheet(proxy: proxy, market: market, onTopUp: {
                selected = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showTopUp = true }
            }, onPurchased: { purchase in
                selected = nil
                dismiss()
                // Outlives this screen: saves the config, selects it and connects on Home.
                Task { @MainActor in
                    await ProxyConnector.addAndConnect(purchase, nodes: nodes, tunnel: tunnel)
                }
            })
            .presentationDetents([.medium, .large])
        }
        .task {
            await account.refreshBalance()
            await market.loadFacets()
            await market.loadHistory()
        }
        .task(id: SearchKey(query: market.query, filters: market.filters)) {
            // Debounce typing, then reload page 1.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await market.reload()
        }
        .onChange(of: account.isLoggedIn) { loggedIn in
            if loggedIn {
                Task {
                    await market.reload()
                    await market.loadHistory()
                    await market.loadFacets()
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.headline)
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")

            BrandLogo(height: 24)
            Spacer(minLength: 0)

            Button { showTopUp = true } label: {
                HStack(spacing: 6) {
                    Circle().fill(Brand.gradient).frame(width: 8, height: 8)
                    Text(account.balanceText)
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                    Image(systemName: "plus")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Brand.orange)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Brand.gradient, lineWidth: 1).opacity(0.6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Wallet balance \(account.balanceText). Top up")

            Button {
                Task {
                    await account.refreshBalance()
                    await market.reload()
                    await market.loadHistory()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.subheadline.weight(.semibold))
                    .rotationEffect(.degrees(account.isRefreshing || market.isLoading ? 360 : 0))
                    .animation(
                        account.isRefreshing || market.isLoading
                            ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
                        value: account.isRefreshing || market.isLoading
                    )
                    .frame(width: 34, height: 34)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Refresh")
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var tabPicker: some View {
        Picker("", selection: $tab) {
            ForEach(Tab.allCases) { tab in
                Text(tab == .history ? "24H List (\(market.history.count))" : tab.rawValue).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.bottom, 10)
    }

    // MARK: - Proxy List

    private var proxyList: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search IP / City / ZIP / ISP", text: $market.query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                    if !market.query.isEmpty {
                        Button { market.query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button { showFilters = true } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.headline)
                        .frame(width: 44, height: 40)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            if market.filters.activeCount > 0 {
                                Text("\(market.filters.activeCount)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 16, height: 16)
                                    .background(Brand.orange, in: Circle())
                                    .offset(x: 5, y: -5)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Filters")
            }
            .padding(.horizontal)

            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(market.items) { proxy in
                        Button { selected = proxy } label: {
                            ProxyCard(proxy: proxy, style: style)
                        }
                        .buttonStyle(.plain)
                        .task { await market.loadMore(after: proxy) }
                    }
                    listFooter
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .refreshable {
                await account.refreshBalance()
                await market.reload()
            }
        }
    }

    @ViewBuilder
    private var listFooter: some View {
        if market.isLoading {
            ProgressView().padding(.vertical, 20)
        } else if let message = market.errorMessage {
            VStack(spacing: 8) {
                Text(message).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                Button("Try again") { Task { await market.reload() } }
                    .font(.footnote.weight(.semibold))
            }
            .padding(.vertical, 20)
        } else if market.items.isEmpty {
            EmptyStateCard(
                icon: "magnifyingglass",
                title: "No proxies found",
                message: market.filters.activeCount > 0 || !market.query.isEmpty
                    ? "Try a different search or clear the filters."
                    : "There are no live proxies right now. Check again soon."
            )
        } else if !market.hasMore {
            Text("\(market.total) live proxies")
                .guideText()
                .padding(.vertical, 12)
        }
    }

    // MARK: - 24H List

    private var historyList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if market.history.isEmpty {
                    if market.historyLoading {
                        ProgressView().padding(.vertical, 30)
                    } else {
                        EmptyStateCard(
                            icon: "clock.arrow.circlepath",
                            title: "Nothing active",
                            message: "Proxies you buy stay here for 24 hours so you can reconnect without paying again."
                        )
                    }
                }
                ForEach(market.history) { purchase in
                    ActiveProxyCard(purchase: purchase, style: style, onExpired: { market.pruneExpired() }) {
                        dismiss()
                        Task { @MainActor in
                            await ProxyConnector.addAndConnect(purchase, nodes: nodes, tunnel: tunnel)
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .refreshable { await market.loadHistory() }
    }

    // MARK: - Signed out

    private var loggedOut: some View {
        VStack(spacing: 16) {
            Spacer()
            EmptyStateCard(
                icon: "person.crop.circle.badge.plus",
                title: "Connect your SailorsLoot account",
                message: "Sign in to browse live proxies, pay from your wallet and connect in one tap."
            )
            Button { account.showLogin = true } label: {
                Label("Connect SailorsLoot Account", systemImage: "person.crop.circle.badge.checkmark")
            }
            .buttonStyle(BrandButtonStyle())
            .padding(.horizontal, 24)
            Button("Close") { dismiss() }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

// MARK: - Cards

/// Proxy card: flag, country, ping, masked IP, price, and State / City / ZIP / ISP.
struct ProxyCard: View {
    let proxy: MarketProxy
    let style: NavigationStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(proxy.flag)
                    .font(.system(size: 26))
                    .frame(width: 44, height: 44)
                    .background(Color(.tertiarySystemBackground), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(proxy.country)
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Image(systemName: "cellularbars")
                            .font(.caption)
                            .foregroundStyle(pingColor)
                        Text(proxy.pingText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(pingColor)
                        Text("•").font(.caption).foregroundStyle(.tertiary)
                        Text(proxy.ipMasked)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 6)
                Text(NairaFormat.string(proxy.price))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Brand.gradient, in: Capsule())
            }
            Divider().opacity(0.4)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    field("State", proxy.state)
                    field("City", proxy.city)
                }
                GridRow {
                    field("ZIP", proxy.zip)
                    field("ISP", proxy.isp)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .navigationStyleCard(style, cornerRadius: 18, padding: 14)
        .contentShape(Rectangle())
    }

    private func field(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value.isEmpty ? "-" : value)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pingColor: Color {
        guard let ms = proxy.pingMs else { return .secondary }
        if ms < 100 { return .green }
        if ms < 300 { return Brand.gold }
        return Brand.orange
    }
}

/// One purchased proxy in the 24H list: countdown and a one-tap Connect.
struct ActiveProxyCard: View {
    let purchase: PurchasedProxy
    let style: NavigationStyle
    let onExpired: () -> Void
    let onConnect: () -> Void

    @EnvironmentObject private var nodes: NodeStore
    @EnvironmentObject private var tunnel: TunnelController

    private var isActive: Bool {
        guard tunnel.isConnected, let node = nodes.activeNode else { return false }
        return node.server == purchase.host && node.port == purchase.port && node.username == purchase.username
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "globe")
                    .font(.title3)
                    .foregroundStyle(Brand.gradient)
                    .frame(width: 40, height: 40)
                    .background(Color(.tertiarySystemBackground), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(purchase.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text([purchase.ip.map(Self.maskIP), purchase.isp].compactMap { $0 }.joined(separator: " • "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 2) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Self.remaining(until: purchase.expiresAt, now: context.date))
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(purchase.expiresAt.timeIntervalSince(context.date) < 1800 ? Brand.orange : Color.green)
                            .onChange(of: purchase.expiresAt.timeIntervalSince(context.date) <= 0) { expired in
                                if expired { onExpired() }
                            }
                    }
                    Text("left").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Button(action: onConnect) {
                Label(isActive ? "Connected" : "Connect", systemImage: isActive ? "checkmark.circle.fill" : "bolt.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isActive ? Color.green : Color.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(isActive ? AnyShapeStyle(Color.green.opacity(0.16)) : AnyShapeStyle(Brand.gradient), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isActive)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .navigationStyleCard(style, cornerRadius: 18, padding: 14)
    }

    static func maskIP(_ ip: String) -> String {
        let parts = ip.split(separator: ".")
        if parts.count == 4 { return "\(parts[0]).\(parts[1]).***.***" }
        return ip.masked
    }

    static func remaining(until end: Date, now: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(now)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }
}
