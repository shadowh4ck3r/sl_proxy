import SwiftUI

/// Home banner: logo, headline, the full body text and a Get button that opens the ad's link.
/// Several banners page sideways (swipe or automatically).
///
/// The card is as tall as its tallest banner, whatever font the device renders (the Sketch app font
/// and a non-jailbroken device wrap the body onto more lines than the system font). Every banner
/// sits in one ZStack and only the current one is visible, so the stack measures itself and the body
/// text is never cut off or abbreviated. A paged `TabView` cannot do this: it needs a fixed height.
struct BannerAdCard: View {
    let banners: [BannerAd]
    let style: NavigationStyle

    @State private var page = 0
    private let timer = Timer.publish(every: 6, on: .main, in: .common).autoconnect()

    private var current: Int { min(page, max(banners.count - 1, 0)) }

    var body: some View {
        ZStack {
            ForEach(Array(banners.enumerated()), id: \.element.id) { index, banner in
                BannerRow(banner: banner, reservesDots: banners.count > 1)
                    .opacity(index == current ? 1 : 0)
                    .allowsHitTesting(index == current)
                    .accessibilityHidden(index != current)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: current)
        .overlay(alignment: .bottom) {
            if banners.count > 1 {
                HStack(spacing: 6) {
                    ForEach(banners.indices, id: \.self) { index in
                        Circle()
                            .fill(index == current ? Brand.orange : Color.secondary.opacity(0.35))
                            .frame(width: 6, height: 6)
                    }
                }
                .padding(.bottom, 8)
                .allowsHitTesting(false)
            }
        }
        .navigationStyleCard(style, cornerRadius: 18, padding: 0)
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    guard banners.count > 1, abs(value.translation.width) > abs(value.translation.height) else { return }
                    let step = value.translation.width < 0 ? 1 : banners.count - 1
                    page = (current + step) % banners.count
                }
        )
        .onReceive(timer) { _ in
            guard banners.count > 1 else { return }
            page = (current + 1) % banners.count
        }
    }
}

private struct BannerRow: View {
    let banner: BannerAd
    /// Leaves room under the text for the page dots.
    let reservesDots: Bool
    /// Starts from the cache, so a logo seen before shows on the first frame.
    @State private var image: UIImage?
    @State private var failed = false

    init(banner: BannerAd, reservesDots: Bool) {
        self.banner = banner
        self.reservesDots = reservesDots
        _image = State(initialValue: BannerImageCache.shared.cached(banner.logo))
    }

    var body: some View {
        HStack(spacing: 12) {
            logo
            .frame(width: 52, height: 52)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                // Concrete colours, not `.primary` / `.secondary` styles: inside the paged TabView on
                // the Katzy frosted-glass card the hierarchical styles lose their vibrancy and the
                // body text disappeared, while the flat Erosion card showed it.
                Text(banner.title)
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(Color(.label))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !banner.subtitle.isEmpty {
                    Text(banner.subtitle)
                        .font(.caption)
                        .foregroundColor(Color(.secondaryLabel))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            if let destination = banner.destination {
                Button {
                    UIApplication.shared.open(destination)
                } label: {
                    Text(banner.cta)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(Brand.gradient, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .padding(.bottom, reservesDots ? 14 : 0)
        .task(id: banner.logo) {
            guard image == nil else { return }
            failed = false
            if let loaded = await BannerImageCache.shared.load(banner.logo) {
                image = loaded
            } else {
                failed = true
            }
        }
    }

    /// The cached logo; a neutral spinner while it downloads; the megaphone only when it failed.
    @ViewBuilder
    private var logo: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
        } else if failed {
            Image(systemName: "megaphone.fill")
                .font(.title2)
                .foregroundStyle(Brand.gradient)
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }
}
