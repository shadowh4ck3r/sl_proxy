import SwiftUI

/// Home banner: logo, headline and a Get button that opens the ad's link. Several banners page
/// sideways and rotate on their own.
struct BannerAdCard: View {
    let banners: [BannerAd]
    let style: NavigationStyle

    @State private var page = 0
    private let timer = Timer.publish(every: 6, on: .main, in: .common).autoconnect()

    var body: some View {
        TabView(selection: $page) {
            ForEach(Array(banners.enumerated()), id: \.element.id) { index, banner in
                BannerRow(banner: banner)
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: banners.count > 1 ? .automatic : .never))
        .frame(height: banners.count > 1 ? 104 : 88)
        .navigationStyleCard(style, cornerRadius: 18, padding: 0)
        .onReceive(timer) { _ in
            guard banners.count > 1 else { return }
            withAnimation { page = (page + 1) % banners.count }
        }
    }
}

private struct BannerRow: View {
    let banner: BannerAd
    /// Starts from the cache, so a logo seen before shows on the first frame.
    @State private var image: UIImage?
    @State private var failed = false

    init(banner: BannerAd) {
        self.banner = banner
        _image = State(initialValue: BannerImageCache.shared.cached(banner.logo))
    }

    var body: some View {
        HStack(spacing: 12) {
            logo
            .frame(width: 52, height: 52)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(banner.title)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                Text(banner.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
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
        .padding(.bottom, 8)
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
