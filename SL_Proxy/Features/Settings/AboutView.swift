import SwiftUI

/// About, stacked like V2Box's: a header with the engraved app icon and the app name, then
/// Information, Support and Credits.
struct AboutView: View {
    var body: some View {
        ZStack {
            Brand.background
            Form {
                Section {
                    VStack(spacing: 10) {
                        EngravedAppIcon()
                        Text("SL_Proxy")
                            .font(.title2.weight(.bold))
                        Text("Premium network utility and proxy client")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }

                Section {
                    LabeledContent("App Version", value: "\(Bundle.main.shortVersion) (\(Bundle.main.buildNumber))")
                    LabeledContent("sing-box Core Version", value: "1.11 (user-space)")
                } header: {
                    Text("Information")
                }

                Section {
                    if let site = URL(string: "https://sailorsloot.xyz") {
                        Link(destination: site) {
                            HStack {
                                SettingsRow(title: "Sailorsloot Website", systemImage: "globe")
                                Spacer()
                                Text("sailorsloot.xyz")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    Text("Support")
                }

                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("A Sailorsloot Project \u{00A9} 2026")
                            .font(.headline)
                            .foregroundStyle(Brand.gradient)
                        creditLine("@poshmipo", role: "Senior Developer / Creator / Software manager")
                        creditLine("@Toolsbrain/Toolsbrain13723", role: "Developer")
                        creditLine("@cptkat", role: "UI designer / Developer")
                        creditLine("@ShadowH4ck3r", role: "uicache / logs input / Proxy Address Engine Config Creator")
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Credits")
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func creditLine(_ handle: String, role: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(handle)
                .font(.subheadline.weight(.semibold))
            Text("(\(role))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

/// The app icon engraved into a small recessed plate. Only the artwork is cut into the surface (the
/// gold lettering and ship, not the black square behind it): the image's brightness becomes the
/// shape, which is then drawn as a groove with a dark edge on the upper left, a light edge on the
/// lower right and a slightly darker floor.
private struct EngravedAppIcon: View {
    private var icon: UIImage? {
        if let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String],
           let name = files.last,
           let image = UIImage(named: name) {
            return image
        }
        return UIImage(named: "Logo")
    }

    private let plate: CGFloat = 84
    private let art: CGFloat = 58

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(.secondarySystemBackground))
                .frame(width: plate, height: plate)
                .overlay(
                    Circle().strokeBorder(
                        LinearGradient(
                            colors: [Color.black.opacity(0.28), Color.white.opacity(0.85)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 2.5
                    )
                )
            if let icon {
                let shape = Image(uiImage: icon)
                    .resizable()
                    .scaledToFit()
                    .luminanceToAlpha()
                    .frame(width: art, height: art)
                ZStack {
                    // Light lip on the lower right edge of the groove.
                    Color.white.opacity(0.9).mask(shape).offset(x: 1, y: 1)
                    // Dark lip on the upper left edge of the groove.
                    Color.black.opacity(0.38).mask(shape).offset(x: -1, y: -1)
                    // The floor of the groove.
                    Color(.systemGray3).mask(shape)
                }
                .frame(width: art, height: art)
            }
        }
        .accessibilityHidden(true)
    }
}
