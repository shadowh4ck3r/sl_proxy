import SwiftUI

/// In-app logo. Falls back to the wordmark until the `Logo` asset is generated
/// (see `scripts/fetch-brand-assets.sh`).
struct BrandLogo: View {
    var height: CGFloat = 32

    var body: some View {
        if UIImage(named: "Logo") != nil {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(height: height)
        } else {
            Text("SL_Proxy")
                .font(.system(size: height * 0.7, weight: .bold, design: .rounded))
                .foregroundStyle(Brand.gradient)
        }
    }
}

extension ProxyKind {
    /// SF Symbol shown in the protocol badge.
    var symbolName: String {
        switch self {
        case .shadowsocks: return "paperplane.fill"
        case .vmess: return "shuffle"
        case .vless: return "bolt.fill"
        case .trojan: return "shield.lefthalf.filled"
        case .socks: return "network"
        case .http: return "globe"
        case .hysteria, .hysteria2: return "flame.fill"
        case .tuic: return "dot.radiowaves.left.and.right"
        case .wireguard: return "key.fill"
        }
    }
}

/// Protocol badge: icon plus short name (for example a paper plane and "SS").
struct KindBadge: View {
    let kind: ProxyKind

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: kind.symbolName)
                .font(.system(size: 9, weight: .bold))
            Text(kind.shortTitle)
                .font(.caption2.weight(.bold))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Brand.gold.opacity(0.18), in: Capsule())
        .foregroundStyle(Brand.orange)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind.title)
    }
}

/// Colour-coded latency capsule: a status dot plus the value ("395 ms", "timeout"), tinted by
/// `LatencyStatus`. Shows nothing until the server has been tested.
struct LatencyPill: View {
    let latency: Int?
    let isTesting: Bool

    private var status: LatencyStatus {
        LatencyStatus(latency: latency, isTesting: isTesting)
    }

    private var text: String {
        switch status {
        case .untested: return ""
        case .testing: return "Testing"
        case .timeout: return "timeout"
        default: return "\(latency ?? 0) ms"
        }
    }

    var body: some View {
        if status != .untested {
            HStack(spacing: 5) {
                if status == .testing {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle()
                        .fill(status.color)
                        .frame(width: 6, height: 6)
                }
                Text(text)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(status.color)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(status.color.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(status.color.opacity(0.35), lineWidth: 1))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(status == .testing ? "Testing latency" : "Latency \(text), \(status.title)")
        }
    }
}

struct NodeRow: View {
    let node: ProxyNode
    let isActive: Bool
    let isTesting: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isActive ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(.tertiary))
            VStack(alignment: .leading, spacing: 3) {
                Text(node.name)
                    .font(.body.weight(isActive ? .semibold : .regular))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    KindBadge(kind: node.kind)
                    Text(node.displayServer)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            LatencyPill(latency: node.latencyMs, isTesting: isTesting)
        }
        .padding(.vertical, 4)
    }
}

struct EmptyStateCard: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Brand.gradient)
            Text(title)
                .font(.headline)
            Text(message)
                .multilineTextAlignment(.center)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .glassCard()
        .padding()
    }
}
