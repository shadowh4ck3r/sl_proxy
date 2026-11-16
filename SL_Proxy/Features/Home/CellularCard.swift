import SwiftUI

/// Home card for the carrier profile: detected SIM, the "Install Your Carrier Profile" button for
/// the matching pipeline-generated `.mobileconfig`, the profile verification badge and, when
/// budgets are on, the cellular usage bars.
struct CellularCard: View {
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var verifier: ProfileVerifier
    @ObservedObject var budget: DataBudgetTracker
    let style: NavigationStyle

    @State private var detection = CarrierDetector.detect()
    /// Seconds since 1970 when a loopback cellular connection was first seen (profile verified);
    /// 0 = never. Kept across launches, so the install buttons stay dismissed while the engine is
    /// stopped. "Reinstall" clears it.
    @AppStorage("profileVerifiedAt") private var verifiedAt: Double = 0
    /// Seconds since 1970 when the install button was last tapped (profile downloaded); 0 = never.
    @AppStorage("profileRequestedAt") private var requestedAt: Double = 0

    private var carrier: Carrier? { settings.value.carrierOverride ?? detection.carrier }

    /// The profile is installed and working: either verified right now or verified earlier.
    private var profileActive: Bool { verifier.state.isVerified || verifiedAt > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "simcard")
                    .font(.title2)
                    .foregroundStyle(Brand.gradient)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text(headline)
                        .font(.headline)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    ProfileVerifiedBadge(state: verifier.state)
                    if verifier.state == .waiting {
                        recheckButton
                    }
                }
            }

            if profileActive {
                // Verified: dismiss "Install your profile" and "Choose your carrier profile" for
                // every carrier, including the Universal profile iOS needs when it hides the SIM.
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Color.green)
                    Text("Profile installed and active")
                        .font(.footnote.weight(.medium))
                    Spacer(minLength: 0)
                    Button("Reinstall") {
                        verifiedAt = 0
                        requestedAt = 0
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Brand.orange)
                    .buttonStyle(.plain)
                }
            } else if let carrier, let url = settings.value.carrierProfileURL(for: carrier) {
                Button {
                    requestedAt = Date().timeIntervalSince1970
                    UIApplication.shared.open(url)
                } label: {
                    Label(requestedAt > 0 ? "Download \(carrier.title) Profile Again" : "Install Your \(carrier.title) Profile",
                          systemImage: "arrow.down.doc")
                }
                .buttonStyle(BrandButtonStyle())
                if requestedAt > 0 {
                    Text("Profile downloaded. Open Settings > General > VPN & Device Management, tap the profile and Install, then connect.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                NavigationLink {
                    CarrierProfileView()
                } label: {
                    Label("Choose Your Carrier Profile", systemImage: "simcard.2")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(Brand.gradient, lineWidth: 1).opacity(0.7))
                }
                .buttonStyle(.plain)
            }

            if settings.value.dataBudgetEnabled {
                budgetBars
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .navigationStyleCard(style, cornerRadius: 18)
        .onAppear {
            detection = CarrierDetector.detect()
            budget.refresh()
            if verifier.state.isVerified { verifiedAt = Date().timeIntervalSince1970 }
        }
        .onChange(of: verifier.state) { state in
            if state.isVerified, verifiedAt == 0 { verifiedAt = Date().timeIntervalSince1970 }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            detection = CarrierDetector.detect()
            budget.refresh()
        }
    }

    // MARK: - Pieces

    /// Shown only while the badge reads "Awaiting cellular traffic": re-detects the carrier and runs
    /// one verifier probe right away instead of waiting for the next poll or a network change.
    private var recheckButton: some View {
        Button {
            Task { await recheck() }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.caption.weight(.semibold))
                .rotationEffect(.degrees(verifier.isRefreshing ? 360 : 0))
                .animation(
                    verifier.isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
                    value: verifier.isRefreshing
                )
                .padding(6)
                .background(Brand.gold.opacity(0.16), in: Circle())
                .foregroundStyle(Brand.gold)
        }
        .buttonStyle(.plain)
        .disabled(verifier.isRefreshing)
        .accessibilityLabel("Re-check carrier profile")
    }

    private func recheck() async {
        detection = CarrierDetector.detect()
        await verifier.refresh()
    }

    private var headline: String {
        if let carrier {
            return settings.value.carrierOverride == nil ? "\(carrier.title) SIM detected" : "\(carrier.title) (chosen manually)"
        }
        if profileActive { return "Cellular profile active" }
        return detection.summary
    }

    private var subtitle: String {
        if let carrier {
            var text = "APN \(carrier.apn) routed through the local proxy"
            if let radio = detection.radioTechnology { text += " · \(radio)" }
            return text
        }
        if profileActive {
            return "Mobile data is routed through the local proxy."
        }
        if detection.isPlaceholder {
            return "Pick Airtel, MTN, Glo or 9mobile in Advanced & Pro > Carrier Profile."
        }
        return "Airtel, MTN, Glo and 9mobile profiles are available."
    }

    private var budgetBars: some View {
        VStack(spacing: 8) {
            ForEach(DataBudgetTracker.Period.allCases, id: \.self) { period in
                if let cap = budget.cap(for: period) {
                    BudgetBar(
                        title: period.title,
                        used: budget.bytes(for: period),
                        cap: cap
                    )
                }
            }
        }
    }
}

/// Colour-coded pill for `ProfileVerifier.State`; green reads "Profile Verified Active".
struct ProfileVerifiedBadge: View {
    let state: ProfileVerifier.State

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption2.weight(.semibold))
            // Allow up to 2 lines and shrink slightly before truncating so the full label
            // ("Profile Verified Active") renders instead of "Profile Verifie...".
            .lineLimit(2)
            .minimumScaleFactor(0.8)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
            .animation(.easeInOut(duration: 0.25), value: state)
            .accessibilityLabel(text)
    }

    private var text: String {
        switch state {
        case .verified: return "Profile Verified Active"
        case .waiting: return "Awaiting cellular traffic"
        case .notCellular: return "On Wi-Fi"
        case .idle: return "Proxy off"
        }
    }

    private var icon: String {
        switch state {
        case .verified: return "checkmark.seal.fill"
        case .waiting: return "antenna.radiowaves.left.and.right"
        case .notCellular: return "wifi"
        case .idle: return "power"
        }
    }

    private var color: Color {
        switch state {
        case .verified: return .green
        case .waiting: return Brand.gold
        case .notCellular, .idle: return .secondary
        }
    }
}

/// One usage bar: title, used / cap and a tinted progress track that turns orange past 90% and
/// red at the cap.
struct BudgetBar: View {
    let title: String
    let used: Int64
    let cap: Int64

    private var fraction: Double { cap > 0 ? min(Double(used) / Double(cap), 1) : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption.weight(.medium))
                Spacer()
                Text("\(TrafficMonitor.bytes(used)) / \(TrafficMonitor.bytes(cap))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: fraction)
                .tint(tint)
        }
    }

    private var tint: Color {
        if fraction >= 1 { return .red }
        if fraction >= 0.9 { return .orange }
        return Brand.orange
    }
}
