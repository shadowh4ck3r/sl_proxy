import SwiftUI

/// Country name for an ISO code, in the user's language.
func marketCountryName(_ code: String) -> String {
    Locale.current.localizedString(forRegionCode: code) ?? code
}

/// ₦ 1,500.00
@MainActor
func marketPrice(_ amount: Double) -> String {
    "\u{20A6}" + SLAccountStore.format(amount)
}

/// One proxy in the live list: flag, country, signal + ping, masked IP, price, and the details.
struct MarketProxyCard: View {
    let listing: SLListing
    @EnvironmentObject private var settings: SettingsStore

    private var status: LatencyStatus { LatencyStatus(latency: listing.pingMs) }

    private var signal: Double {
        switch listing.pingMs ?? Int.max {
        case ..<60: return 1
        case ..<150: return 0.75
        case ..<300: return 0.5
        default: return 0.25
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(listing.flag)
                    .font(.system(size: 28))
                    .frame(width: 46, height: 46)
                    .background(Brand.gold.opacity(0.15), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(marketCountryName(listing.countryCode))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if listing.pingMs != nil {
                            Image(systemName: "cellularbars", variableValue: signal)
                                .font(.caption)
                                .foregroundStyle(status.color)
                            Text("\(listing.pingMs ?? 0)ms")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(status.color)
                            Text("\u{2022}").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(listing.ipMasked)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 6)
                Text(marketPrice(listing.price))
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Brand.gradient, in: Capsule())
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    field("State", listing.state)
                    field("City", listing.city)
                }
                GridRow {
                    field("ZIP", listing.zip)
                    field("ISP", listing.isp)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .navigationStyleCard(settings.value.navigationStyle, cornerRadius: 18, padding: 14)
    }

    private func field(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "-" : value)
                .font(.footnote.weight(.medium))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One purchased proxy in the 24H list: place, masked IP, a live countdown and a Connect button.
struct PurchasedProxyCard: View {
    let purchase: SLPurchased
    let isActive: Bool
    let onConnect: () -> Void
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, purchase.expiresAt.timeIntervalSince(context.date))
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(purchase.city.isEmpty ? purchase.country : "\(purchase.city), \(purchase.country)")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(purchase.ipMasked)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Label(Self.countdown(remaining), systemImage: "timer")
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(remaining > 0 ? (remaining < 1800 ? Color.orange : Color.green) : Color.red)
                }
                Spacer(minLength: 6)
                Button(action: onConnect) {
                    Text(remaining <= 0 ? "Expired" : (isActive ? "In use" : "Connect"))
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            remaining <= 0 || isActive ? AnyShapeStyle(Color.gray) : AnyShapeStyle(Brand.gradient),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .disabled(remaining <= 0 || isActive)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .navigationStyleCard(settings.value.navigationStyle, cornerRadius: 18, padding: 14)
        }
    }

    static func countdown(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
