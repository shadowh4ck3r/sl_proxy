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
                        creditLine("@poshmipo", role: "Senior Developer")
                        creditLine("@Toolsbrain/Toolsbrain13723", role: "Developer")
                        creditLine("@9god", role: "Creator / Software manager")
                        creditLine("@cptkat", role: "UI designer / Developer")
                        creditLine("@ShadowH4ck3r", role: "uicache / logs input")
                        creditLine("@XYZ Aro El_ArbustoGato III", role: "Proxy Address Engine Config Creator")
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

/// The app icon pressed into a recessed round plate: a light edge on the lower rim, a dark one on
/// the upper rim and a soft shadow inside, so it looks engraved rather than printed.
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

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.black.opacity(0.22), Color.white.opacity(0.35)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 118, height: 118)
            Circle()
                .fill(Color(.secondarySystemBackground))
                .frame(width: 108, height: 108)
                .overlay(
                    Circle().strokeBorder(
                        LinearGradient(
                            colors: [Color.black.opacity(0.35), Color.white.opacity(0.9)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 3
                    )
                )
            if let icon {
                Image(uiImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 70, height: 70)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: Color.white.opacity(0.9), radius: 0.5, x: 1, y: 1)
                    .shadow(color: Color.black.opacity(0.4), radius: 1.5, x: -1, y: -1)
                    .saturation(0.85)
                    .opacity(0.95)
            }
        }
        .accessibilityHidden(true)
    }
}
