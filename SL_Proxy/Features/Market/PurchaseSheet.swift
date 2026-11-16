import SwiftUI

/// Purchase confirmation. The server does the real work (balance check, live IP check, atomic
/// debit, 24h log) and only then hands back the credentials, which the caller saves and connects.
struct PurchaseSheet: View {
    let proxy: MarketProxy
    @ObservedObject var market: MarketStore
    let onTopUp: () -> Void
    let onPurchased: (PurchasedProxy) -> Void

    @ObservedObject private var account = AccountStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var isBuying = false
    @State private var errorText: String?

    private var balance: Double { account.balance ?? 0 }
    private var canAfford: Bool { balance >= proxy.price }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    HStack(spacing: 12) {
                        Text(proxy.flag)
                            .font(.system(size: 30))
                            .frame(width: 50, height: 50)
                            .background(Color(.tertiarySystemBackground), in: Circle())
                        VStack(alignment: .leading, spacing: 3) {
                            Text(proxy.country).font(.headline)
                            Text("\(proxy.city), \(proxy.state)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("\(proxy.ipMasked) • \(proxy.pingText)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    VStack(spacing: 10) {
                        row("ISP", proxy.isp)
                        row("ZIP", proxy.zip)
                        row("Valid for", "24 hours")
                        Divider().opacity(0.4)
                        row("Price", NairaFormat.string(proxy.price), bold: true)
                        row("Wallet", account.balanceText)
                        row("After purchase", canAfford ? NairaFormat.string(balance - proxy.price) : "Not enough balance",
                            tint: canAfford ? nil : .red)
                    }
                    .padding(14)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    if let errorText {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }

                    if canAfford {
                        Button { Task { await buy() } } label: {
                            if isBuying {
                                HStack(spacing: 10) {
                                    ProgressView().tint(.white)
                                    Text("Checking the proxy is live...")
                                }
                            } else {
                                Label("Buy & Connect", systemImage: "bolt.fill")
                            }
                        }
                        .buttonStyle(BrandButtonStyle())
                        .disabled(isBuying)
                    } else {
                        Button(action: onTopUp) {
                            Label("Top Up Wallet", systemImage: "plus.circle.fill")
                        }
                        .buttonStyle(BrandButtonStyle())
                    }

                    Text("You are charged only after the proxy passes a live check. Credentials are saved to Configs and the connection starts automatically.")
                        .guideText()
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
            .navigationTitle("Confirm Purchase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }.disabled(isBuying)
                }
            }
        }
        .interactiveDismissDisabled(isBuying)
    }

    private func row(_ title: String, _ value: String, bold: Bool = false, tint: Color? = nil) -> some View {
        HStack {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(bold ? .bold : .medium).monospacedDigit())
                .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
        }
    }

    private func buy() async {
        guard !isBuying else { return }
        isBuying = true
        errorText = nil
        defer { isBuying = false }
        do {
            let purchase = try await market.purchase(proxy)
            onPurchased(purchase)
        } catch SLAPIError.unauthorized {
            dismiss() // AccountStore shows the sign-in screen
        } catch {
            errorText = error.localizedDescription
            await account.refreshBalance()
        }
    }
}
