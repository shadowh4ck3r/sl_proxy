import SwiftUI

/// Appearance Settings, laid out like V2Box: a Theme section, a Navigation Style section with
/// tappable preview cards and the Connect button options under them, and a Reset button.
///
/// There is no local state here. Every control binds straight to `AppSettings` through the global
/// `SettingsStore` (`@EnvironmentObject`, injected in `SLProxyApp`), so the choices persist across
/// launches and every observer re-renders on the spot: `HomeView` resizes and re-docks its Connect
/// button and switches card style, `ContentView` shows or hides the floating Connect button on the
/// other tabs. Nothing here reaches the engine: `TunnelController.applyChanges()` regenerates the
/// sing-box config on settings changes, finds it unchanged and leaves the running core alone.
struct AppearanceSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject private var ota = OTAFlags.shared
    @AppStorage(HomeLayoutStyle.storageKey) private var storedLayout = ""

    private var layoutSelection: Binding<HomeLayoutStyle> {
        Binding(
            get: { HomeLayoutStyle.resolve(stored: storedLayout, otaDefault: ota.defaultHomeLayout) },
            set: { storedLayout = $0.rawValue }
        )
    }

    var body: some View {
        ZStack {
            Brand.background
            Form {
                Section {
                    Picker("Home Screen Style", selection: layoutSelection) {
                        ForEach(HomeLayoutStyle.allCases) { layout in
                            Text(LocalizedStringKey(layout.title)).tag(layout)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section {
                    Picker("Theme", selection: $settings.value.colorScheme) {
                        ForEach(AppColorScheme.allCases) { scheme in
                            Text(scheme.title).tag(scheme)
                        }
                    }
                    .pickerStyle(.menu)
                    Picker("App Font", selection: $settings.value.fontStyle) {
                        ForEach(AppFontStyle.allCases) { font in
                            Text(font.title).tag(font)
                        }
                    }
                    .pickerStyle(.menu)
                    AppFontPreview(style: settings.value.fontStyle)
                } header: {
                    Text("Theme")
                } footer: {
                    Text("System Default follows the iOS appearance setting. Light and Dark override it for this app only. \(settings.value.fontStyle.detail)")
                    .font(.caption2)
                }

                Section {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(NavigationStyle.allCases) { style in
                            NavigationStyleOption(
                                style: style,
                                isSelected: settings.value.navigationStyle == style
                            )
                            .onTapGesture { settings.value.navigationStyle = style }
                        }
                    }
                    .padding(.vertical, 6)
                    Picker("Connection Button Size", selection: $settings.value.connectionButtonSize) {
                        ForEach(ConnectionButtonSize.allCases) { size in
                            Text(size.title).tag(size)
                        }
                    }
                    .pickerStyle(.menu)
                    Toggle("Fixed Button Position", isOn: $settings.value.fixedButtonPosition)
                    Toggle("Show only in Home Tab", isOn: $settings.value.showButtonOnlyInHomeTab)
                    if settings.value.connectButtonX != nil {
                        Button("Reset button position") {
                            settings.value.connectButtonX = nil
                            settings.value.connectButtonY = nil
                        }
                    }
                } header: {
                    Text("Navigation Style")
                } footer: {
                    Text("\(settings.value.navigationStyle.detail) \(buttonFooter)")
                    .font(.caption2)
                }

                Section {
                    Button(role: .destructive) {
                        storedLayout = HomeLayoutStyle.classic.rawValue
                        resetAppearance()
                    } label: {
                        Text("Reset Appearance Settings")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var buttonFooter: String {
        var text = settings.value.fixedButtonPosition
            ? "The Connect button floats over the screen: drag it anywhere and it stays there. Home shows a one-line status instead of the big card"
            : "The Connect button is part of the Home card and scrolls with it"
        text += settings.value.showButtonOnlyInHomeTab
            ? ", and is shown on the Home tab only."
            : ", and floats over the other tabs too."
        return text
    }

    /// Puts every appearance option back to its default and leaves the other settings alone.
    private func resetAppearance() {
        let defaults = AppSettings()
        var updated = settings.value
        updated.colorScheme = defaults.colorScheme
        updated.fontStyle = defaults.fontStyle
        updated.navigationStyle = defaults.navigationStyle
        updated.connectionButtonSize = defaults.connectionButtonSize
        updated.fixedButtonPosition = defaults.fixedButtonPosition
        updated.showButtonOnlyInHomeTab = defaults.showButtonOnlyInHomeTab
        updated.connectButtonX = nil
        updated.connectButtonY = nil
        settings.value = updated
    }
}

/// Live sample of the selected App Font: a title, a host:port string (where Mono matters most) and
/// the chosen style's name, all rendered with that font design.
private struct AppFontPreview: View {
    let style: AppFontStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SL_Proxy")
                .font(.headline)
                .foregroundStyle(Brand.gradient)
            Text("127.0.0.1:20080")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .font(.system(.body, design: style.design))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .animation(.easeInOut(duration: 0.2), value: style)
        .accessibilityLabel("\(style.title) font preview")
    }
}

/// One selectable Navigation Style card: a small mock screen plus the style name, with a check
/// badge on the selected one. Selection is handled by the caller (`onTapGesture`), because buttons
/// side by side in one Form row all fire together.
private struct NavigationStyleOption: View {
    let style: NavigationStyle
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 10) {
            NavigationStyleThumbnail(style: style)
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.white, Brand.orange)
                            .offset(x: 6, y: -6)
                    }
                }
            Text(style.title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(isSelected ? Brand.gold.opacity(0.25) : Color.clear, in: Capsule())
                .foregroundStyle(isSelected ? Brand.orange : Color.secondary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.2), value: isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(style.title) navigation style")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Mock Home screen: two cards in the style (flat with a solid edge for Erosion, frosted with a
/// gradient edge for Katzy) and the Connect button docked at the bottom-left: the vintage wooden
/// switch for Erosion, the glass ring for Katzy.
private struct NavigationStyleThumbnail: View {
    let style: NavigationStyle

    private let corner: CGFloat = 16

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Color(.systemBackground))
            if style.usesGlassmorphism {
                // Something colourful behind the cards so the frosted material is visible.
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Brand.gradient)
                    .opacity(0.35)
            }
            VStack(spacing: 6) {
                miniCard
                miniCard
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Group {
                if style.usesGlassmorphism {
                    Circle()
                        .fill(Brand.gradient)
                        .frame(width: 22, height: 22)
                } else {
                    VintageConnectSwitch(height: 24, isOn: true, action: {})
                        .allowsHitTesting(false)
                }
            }
            .padding(8)
        }
        .frame(height: 104)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Brand.orange.opacity(0.35), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var miniCard: some View {
        if style.usesGlassmorphism {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Brand.gradient, lineWidth: 1)
                )
                .frame(height: 22)
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(.secondarySystemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Brand.orange.opacity(0.4), lineWidth: 1)
                )
                .frame(height: 22)
        }
    }
}
