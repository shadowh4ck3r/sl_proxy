import SwiftUI

// MARK: - Palette

/// Colours of the signed-out Proxies screen for one appearance. Everything that differs between
/// Light and Dark Mode lives here, so the views below never branch on the colour scheme themselves.
struct SignedOutPalette {
    let background: Color
    let title: Color
    let subtitle: Color
    let badgeFill: Color
    let badgeBorder: Color?
    let badgeTitle: Color
    let badgeSubtitle: Color
    let badgeShadow: Bool
    let statCircle: Color
    let statIcon: Color
    let statLabel: Color
    let accent: Color
    let mapImage: String

    static let dark = SignedOutPalette(
        background: Color(hex: "#0D0A07"),
        title: Color(hex: "#FFFFFF"),
        subtitle: Color(hex: "#A1A1AA"),
        badgeFill: Color(hex: "#1C1917").opacity(0.85),
        badgeBorder: Color(hex: "#F59E0B").opacity(0.25),
        badgeTitle: .white,
        badgeSubtitle: Color(hex: "#A1A1AA"),
        badgeShadow: false,
        statCircle: Color(hex: "#291D12"),
        statIcon: Color(hex: "#F59E0B"),
        statLabel: Color(hex: "#FFFFFF"),
        accent: Color(hex: "#F59E0B"),
        mapImage: "proxy_map_dark"
    )

    static let light = SignedOutPalette(
        background: Color(hex: "#FAF9F6"),
        title: Color(hex: "#111827"),
        subtitle: Color(hex: "#4B5563"),
        badgeFill: Color.white.opacity(0.92),
        badgeBorder: nil,
        badgeTitle: Color(hex: "#111827"),
        badgeSubtitle: Color(hex: "#4B5563"),
        badgeShadow: true,
        statCircle: Color(hex: "#FEF3C7"),
        statIcon: Color(hex: "#D97706"),
        statLabel: Color(hex: "#111827"),
        accent: Color(hex: "#D97706"),
        mapImage: "proxy_map_light"
    )

    static func forScheme(_ scheme: ColorScheme) -> SignedOutPalette {
        scheme == .dark ? .dark : .light
    }
}

/// Solid screen background of the signed-out Proxies tab (the Proxies header and switcher draw on top).
struct SignedOutBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        SignedOutPalette.forScheme(scheme).background.ignoresSafeArea()
    }
}

// MARK: - Country badges

/// One floating "flag, country, IP count" chip. `x` and `y` place it over the map: `x` is a fraction
/// of the screen width, `y` a fraction of the map band (0 = top of the continents, 1 = bottom).
struct CountryBadge: Identifiable {
    let id: String
    let flag: String
    let name: String
    let ips: String
    let x: CGFloat
    let y: CGFloat

    /// Edit the numbers here to move a chip; nothing else needs to change.
    static let all: [CountryBadge] = [
        CountryBadge(id: "us", flag: "🇺🇸", name: "United States", ips: "640,800 IPs", x: 0.20, y: 0.22),
        CountryBadge(id: "uk", flag: "🇬🇧", name: "United Kingdom", ips: "485,200 IPs", x: 0.43, y: 0.42),
        CountryBadge(id: "de", flag: "🇩🇪", name: "Germany", ips: "612,400 IPs", x: 0.74, y: 0.22),
        CountryBadge(id: "br", flag: "🇧🇷", name: "Brazil", ips: "340,900 IPs", x: 0.24, y: 0.74),
        CountryBadge(id: "sg", flag: "🇸🇬", name: "Singapore", ips: "415,600 IPs", x: 0.78, y: 0.56),
        CountryBadge(id: "au", flag: "🇦🇺", name: "Australia", ips: "278,150 IPs", x: 0.55, y: 0.84),
    ]
}

struct CountryBadgeView: View {
    let badge: CountryBadge
    let palette: SignedOutPalette
    var compact = false

    var body: some View {
        HStack(spacing: 6) {
            Text(badge.flag)
                .font(.system(size: compact ? 16 : 20))
            VStack(alignment: .leading, spacing: 0) {
                Text(badge.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(palette.badgeTitle)
                Text(badge.ips)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(palette.badgeSubtitle)
            }
            .lineLimit(1)
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, compact ? 4 : 5)
        .background(palette.badgeFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            if let border = palette.badgeBorder {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(border, lineWidth: 1)
            }
        }
        .shadow(color: palette.badgeShadow ? Color.black.opacity(0.12) : .clear, radius: 4, y: 2)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Feature highlights

struct FeatureStatItem: View {
    let icon: String
    let label: String
    let palette: SignedOutPalette
    var circle: CGFloat = 44

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: circle * 0.42, weight: .semibold))
                .foregroundColor(palette.statIcon)
                .frame(width: circle, height: circle)
                .background(palette.statCircle, in: Circle())
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(palette.statLabel)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Screen

/// Signed-out state of the Proxies tab. The map takes whatever height is left after the branding,
/// the three highlights and the button, so everything fits between the Proxies switcher and the tab
/// bar without scrolling: the content shrinks one step on small iPhones (SE / mini) and the map
/// shrinks with it.
struct SignedOutProxiesView: View {
    let onConnect: () -> Void
    let onSignUp: () -> Void

    @Environment(\.colorScheme) private var scheme

    private var palette: SignedOutPalette { .forScheme(scheme) }

    /// Spacing and sizes for one screen height. `tier 0` is a Pro / Pro Max, `1` an SE or mini.
    private struct Metrics {
        let logo: CGFloat
        let title: CGFloat
        let body: CGFloat
        let circle: CGFloat
        let button: CGFloat
        let gap: CGFloat

        init(height: CGFloat) {
            if height >= 500 {
                logo = 42; title = 22; body = 13; circle = 44; button = 50; gap = 12
            } else {
                logo = 30; title = 20; body = 12; circle = 36; button = 46; gap = 8
            }
        }
    }

    private static let description =
        "Live SOCKS5 servers with real-time monitoring, built directly into our proxy client for effortless setup and instant auto-connection after purchase. Get started in under 2 seconds and stay connected globally."

    var body: some View {
        GeometryReader { proxy in
            let m = Metrics(height: proxy.size.height)
            VStack(spacing: 0) {
                MapBanner(palette: palette, width: proxy.size.width)
                    .frame(maxWidth: .infinity, minHeight: 90, maxHeight: .infinity)
                    .layoutPriority(-1)
                content(m)
                    .padding(.bottom, 6)
            }
        }
    }

    private func content(_ m: Metrics) -> some View {
        VStack(spacing: m.gap) {
            logo(m)
            Text("Welcome to SL_Proxy 🧦5")
                .font(.system(size: m.title, weight: .bold))
                .foregroundColor(palette.title)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(Self.description)
                .font(.system(size: m.body))
                .foregroundColor(palette.subtitle)
                .multilineTextAlignment(.center)
                .lineLimit(6)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 24)
            HStack(alignment: .top, spacing: 0) {
                FeatureStatItem(icon: "mappin.and.ellipse", label: "35M+ IPs", palette: palette, circle: m.circle)
                FeatureStatItem(icon: "globe", label: "120+ Countries", palette: palette, circle: m.circle)
                FeatureStatItem(icon: "server.rack", label: "12K+ Servers", palette: palette, circle: m.circle)
            }
            .padding(.horizontal, 12)
            connectButton(m)
            signUpLine
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The real SL>_ logo image, the same asset the Home header uses (`Logo`; a dedicated `sl_logo`
    /// asset wins when one exists). Never drawn as text: the text fallback rendered as a plain
    /// glyph in the app font instead of the brand mark. Both assets keep their transparency, so
    /// the mark reads on the light and the dark background.
    @ViewBuilder
    private func logo(_ m: Metrics) -> some View {
        if UIImage(named: "sl_logo") != nil {
            Image("sl_logo")
                .resizable()
                .scaledToFit()
                .frame(height: m.logo)
                .accessibilityLabel("SL_Proxy")
        } else {
            BrandLogo(height: m.logo)
                .accessibilityLabel("SL_Proxy")
        }
    }

    private func connectButton(_ m: Metrics) -> some View {
        Button(action: onConnect) {
            Label("Connect SailorsLoot Account", systemImage: "person.crop.circle.badge.checkmark")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: m.button)
                .background(
                    LinearGradient(
                        colors: [Color(hex: "#EAB308"), Color(hex: "#F97316")],
                        startPoint: .leading, endPoint: .trailing
                    ),
                    in: Capsule()
                )
                .shadow(color: Color(hex: "#F97316").opacity(0.35), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
    }

    private var signUpLine: some View {
        Button(action: onSignUp) {
            (Text("If you don't have a SailorsLoot account, ")
                .foregroundColor(palette.subtitle)
             + Text("Sign up")
                .fontWeight(.bold)
                .foregroundColor(palette.accent))
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.85)
                .lineLimit(2)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
    }
}

// MARK: - Map

/// The world map with the floating country chips. The picture is filled into the available area and
/// faded into the screen background at the bottom edge.
private struct MapBanner: View {
    let palette: SignedOutPalette
    let width: CGFloat

    /// Height of the continents as a share of the screen width, per picture. Keeps the chips on
    /// their regions when the area is taller or shorter than the picture.
    private var bandAspect: CGFloat { palette.mapImage == "proxy_map_dark" ? 0.62 : 0.74 }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                palette.background
                Image(palette.mapImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
                // Fade the map into the screen background (and a little at the top, under the switcher).
                VStack(spacing: 0) {
                    LinearGradient(colors: [palette.background, palette.background.opacity(0)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: size.height * 0.12)
                    Spacer(minLength: 0)
                    LinearGradient(colors: [palette.background.opacity(0), palette.background],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: size.height * 0.42)
                }
                badges(in: size)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
        .accessibilityHidden(true)
    }

    /// Chips sit in a band centred in the area. When the area is shorter than the continents' band
    /// the band is squeezed (chips stay on screen, only slightly off their exact region).
    private func badges(in size: CGSize) -> some View {
        let compact = size.height < 190
        let band = min(width * bandAspect, size.height - 40)
        let originY = (size.height - band) / 2 - size.height * 0.04
        // Fewer chips when there is little room, so they never pile up.
        let shown = compact ? CountryBadge.all.filter { ["uk", "de", "br", "sg"].contains($0.id) } : CountryBadge.all
        return ZStack {
            ForEach(shown) { badge in
                CountryBadgeView(badge: badge, palette: palette, compact: compact)
                    .position(x: badge.x * size.width, y: originY + badge.y * band)
            }
        }
    }
}

#if DEBUG
#Preview("Signed out · dark") {
    SignedOutProxiesView(onConnect: {}, onSignUp: {})
        .background(SignedOutBackground())
        .preferredColorScheme(.dark)
}

#Preview("Signed out · light") {
    SignedOutProxiesView(onConnect: {}, onSignUp: {})
        .background(SignedOutBackground())
        .preferredColorScheme(.light)
}
#endif
