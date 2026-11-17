import SwiftUI

/// Renders the server-driven components of `ui.json` for one placement (`home.top`, `home.bottom`,
/// `settings.top`). It draws nothing at all when no component is active, so the native screen is
/// exactly what it was before OTA existed whenever the server has nothing to show or the site is
/// unreachable.
///
///     DynamicOTAView(placement: "home.top")
///
/// Needs `OTAManager` in the environment (`ContentView` injects it).
struct DynamicOTAView: View {
    let placement: String

    @EnvironmentObject private var ota: OTAManager
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        let items = ota.components(for: placement)
        if items.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 12) {
                ForEach(items) { component in
                    OTAComponentView(component: component, style: settings.value.navigationStyle)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: items.map(\.id))
        }
    }
}

// MARK: - One component

private struct OTAComponentView: View {
    let component: OTAComponent
    let style: NavigationStyle

    @EnvironmentObject private var ota: OTAManager

    var body: some View {
        switch component.type {
        case "banner", "card": infoCard
        case "button": actionButton
        case "toggle": toggleRow
        default: EmptyView()
        }
    }

    private var infoCard: some View {
        HStack(alignment: .center, spacing: 12) {
            if let image = component.imageURL {
                OTARemoteImage(urlString: image)
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if let icon = component.icon {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(Brand.gradient)
                    .frame(width: 40)
            }
            VStack(alignment: .leading, spacing: 3) {
                if let title = component.title {
                    Text(title)
                        .font(.subheadline.weight(.bold))
                        .foregroundColor(Color(.label))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let body = component.body {
                    Text(body)
                        .font(.caption)
                        .foregroundColor(Color(.secondaryLabel))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            if let label = component.buttonTitle, component.action != nil {
                Button {
                    ota.perform(component.action, from: component)
                } label: {
                    Text(label)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(Brand.gradient, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) { dismissButton }
        .navigationStyleCard(style, cornerRadius: 18, padding: 0)
    }

    @ViewBuilder
    private var dismissButton: some View {
        if component.dismissible == true {
            Button {
                ota.dismiss(component.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color(.tertiaryLabel))
                    .padding(6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
    }

    private var actionButton: some View {
        Button {
            ota.perform(component.action, from: component)
        } label: {
            Text(component.title ?? component.buttonTitle ?? "Continue")
        }
        .buttonStyle(BrandButtonStyle())
    }

    private var toggleRow: some View {
        let key = component.key ?? component.id
        return Toggle(isOn: Binding(
            get: { ota.flag(key, default: false) },
            set: { value in
                ota.setFlag(key, value)
                // The action (usually a `js` call) receives the new value as its last argument.
                ota.perform(component.action, from: component, extraArgs: [value])
            }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                if let title = component.title { Text(title).font(.subheadline.weight(.semibold)) }
                if let body = component.body {
                    Text(body).font(.caption).foregroundColor(Color(.secondaryLabel))
                }
            }
        }
        .tint(Brand.orange)
        .padding(14)
        .navigationStyleCard(style, cornerRadius: 18, padding: 0)
    }
}

/// Image from the shared banner cache (instant when seen before).
private struct OTARemoteImage: View {
    let urlString: String
    @State private var image: UIImage?

    init(urlString: String) {
        self.urlString = urlString
        _image = State(initialValue: BannerImageCache.shared.cached(urlString))
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Color.clear
            }
        }
        .task(id: urlString) {
            guard image == nil else { return }
            image = await BannerImageCache.shared.load(urlString)
        }
    }
}

// MARK: - Announcement modal

extension View {
    /// Presents the first unseen `modal` component of `ui.json` as a sheet. Attach once, to the root
    /// view (`ContentView`).
    func otaModals(_ ota: OTAManager) -> some View {
        modifier(OTAModalModifier(ota: ota))
    }
}

private struct OTAModalModifier: ViewModifier {
    @ObservedObject var ota: OTAManager

    func body(content: Content) -> some View {
        content.sheet(item: Binding(
            get: { ota.pendingModal },
            set: { newValue in
                if newValue == nil, let closing = ota.pendingModal { ota.markModalSeen(closing) }
                ota.pendingModal = newValue
            }
        )) { modal in
            OTAModalView(component: modal, ota: ota)
        }
    }
}

private struct OTAModalView: View {
    let component: OTAComponent
    @ObservedObject var ota: OTAManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 12)
            if let image = component.imageURL {
                OTARemoteImage(urlString: image)
                    .frame(height: 96)
            } else {
                Image(systemName: component.icon ?? "megaphone.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(Brand.gradient)
            }
            if let title = component.title {
                Text(title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
            }
            if let body = component.body {
                Text(body)
                    .font(.body)
                    .foregroundColor(Color(.secondaryLabel))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if component.action != nil {
                Button(component.buttonTitle ?? "OK") {
                    ota.perform(component.action, from: component)
                    dismiss()
                }
                .buttonStyle(BrandButtonStyle())
            }
            Button(component.action == nil ? "Close" : "Not now") { dismiss() }
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .presentationDetents([.medium])
    }
}
