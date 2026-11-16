import SwiftUI

/// Confirmation before buying: details, price, balance after the purchase, then Buy & Connect.
struct PurchaseSheet: View {
    let listing: SLListing
    @EnvironmentObject private var account: SLAccountStore
    @EnvironmentObject private var market: ProxyMarketStore
    @Environment(\.dismiss) private var dismiss
    @State private var showTopUp = false

    private var balance: Double { account.balance ?? 0 }
    private var affordable: Bool { balance >= listing.price }
    private var isBuying: Bool { market.buyingID == listing.id }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 6) {
                        Text(listing.flag).font(.system(size: 54))
                        Text(marketCountryName(listing.countryCode))
                            .font(.title3.weight(.semibold))
                        Text(listing.ipMasked)
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    VStack(spacing: 0) {
                        row("State", listing.state)
                        row("City", listing.city)
                        row("ZIP", listing.zip)
                        row("ISP", listing.isp)
                        row("Type", listing.type)
                        if let ping = listing.pingMs { row("Ping", "\(ping) ms") }
                    }
                    .padding(.horizontal, 14)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    VStack(spacing: 0) {
                        row("Price", marketPrice(listing.price), bold: true)
                        row("Your balance", account.balanceText)
                        row("After purchase", affordable ? marketPrice(balance - listing.price) : "Not enough")
                    }
                    .padding(.horizontal, 14)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    if !affordable {
                        Text("Your wallet does not cover this proxy. Top up on sailorsloot.xyz, then come back.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                        Button {
                            showTopUp = true
                        } label: {
                            Label("Top Up Wallet", systemImage: "plus.circle")
                        }
                        .buttonStyle(BrandButtonStyle())
                    } else {
                        Button {
                            Task {
                                if await market.buy(listing) != nil { dismiss() }
                            }
                        } label: {
                            if isBuying {
                                HStack(spacing: 8) {
                                    ProgressView().tint(.white)
                                    Text("Checking the IP is live...")
                                }
                            } else {
                                Label("Buy & Connect", systemImage: "bolt.fill")
                            }
                        }
                        .buttonStyle(BrandButtonStyle())
                        .disabled(isBuying)
                        Text(isBuying
                             ? "This can take up to a minute. You are only charged if the IP is live."
                             : "The IP is checked live first and you are only charged if it works. The proxy is saved to Configs, selected and connected.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    if let message = market.errorMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding()
            }
            .background(Brand.background)
            .navigationTitle("Buy proxy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .disabled(isBuying)
                }
            }
            .sheet(isPresented: $showTopUp) {
                SafariView(url: SLConfig.topUpURL).ignoresSafeArea()
            }
            .onChange(of: showTopUp) { open in
                if !open { Task { await account.refreshBalance() } }
            }
            .onAppear { market.errorMessage = nil }
        }
        .interactiveDismissDisabled(isBuying)
        .presentationDetents([.large])
    }

    private func row(_ title: String, _ value: String, bold: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value.isEmpty ? "-" : value)
                .font(bold ? .subheadline.weight(.bold) : .subheadline)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 10)
    }
}
