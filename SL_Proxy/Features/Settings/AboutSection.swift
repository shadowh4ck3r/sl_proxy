import SwiftUI

/// App icon as installed (works with the asset-catalog AppIcon).
enum AppIconImage {
    static var image: UIImage? {
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let name = files.last else { return nil }
        return UIImage(named: name)
    }
}

/// V2Box-style About header where V2Box shows its world map: the SL_Proxy app icon, engraved
/// into the card (recessed well, inner shadow, light edge), with the SL_Proxy name underneath.
struct AboutHeaderCard: View {
    var body: some View {
        VStack(spacing: 12) {
            engravedIcon
            Text("SL_Proxy")
                .font(.title3.weight(.bold))
                .foregroundStyle(Brand.gradient)
            Text("Version \(Bundle.main.shortVersion) (\(Bundle.main.buildNumber))")
                .guideText()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Brand.orange.opacity(0.25), lineWidth: 1))
    }

    private var engravedIcon: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        return ZStack {
            // Recessed well.
            shape
                .fill(LinearGradient(colors: [Color.black.opacity(0.32), Color.white.opacity(0.06)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 96, height: 96)
            // The icon, slightly inset and toned down like stamped metal.
            Group {
                if let icon = AppIconImage.image {
                    Image(uiImage: icon).resizable().scaledToFill()
                } else {
                    BrandLogo(height: 54)
                }
            }
            .frame(width: 80, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .saturation(0.9)
            .opacity(0.96)
            // Inner shadow along the top-left edge, light catching the bottom-right lip.
            shape
                .strokeBorder(LinearGradient(colors: [Color.black.opacity(0.55), .clear, Color.white.opacity(0.45)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 4)
                .blur(radius: 1.6)
                .frame(width: 96, height: 96)
                .clipShape(shape)
        }
        .shadow(color: Color.white.opacity(0.35), radius: 0, x: 1, y: 1)
        .accessibilityHidden(true)
    }
}

/// The About stack for the bottom of Settings: engraved header card, then Website (replaces the
/// Telegram community row) and version rows. Use inside the Settings list:  `SettingsAboutStack()`
struct SettingsAboutStack: View {
    var body: some View {
        Section {
            AboutHeaderCard()
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                .listRowBackground(Color.clear)
            Link(destination: SailorsLootLinks.site) {
                HStack(spacing: 12) {
                    Image(systemName: "globe")
                        .foregroundStyle(Brand.gradient)
                        .frame(width: 24)
                    Text("Sailorsloot Website")
                    Spacer()
                    Text("sailorsloot.xyz").guideText()
                    Image(systemName: "arrow.up.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.primary)
        } header: {
            Text("About")
        }
    }
}
