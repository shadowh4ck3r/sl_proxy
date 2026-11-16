import Foundation

/// One banner ad from the Sailorsloot website. The admin edits them in WordPress (SL App Banners,
/// see `backend/sl_banner_ads.php`); the app only reads them.
struct BannerAd: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let logo: String
    let url: String
    let cta: String

    /// Only http(s) links are ever opened, whatever the server sends.
    var destination: URL? {
        guard let url = URL(string: url), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        return url
    }
}

@MainActor
final class BannerStore: ObservableObject {
    static let endpoint = URL(string: "https://sailorsloot.xyz/wp-json/slapp/v1/banners")!

    @Published private(set) var banners: [BannerAd] = []

    private struct Payload: Codable {
        let banners: [BannerAd]
    }

    private let cacheKey = "slapp.banners.cache"

    init() {
        // Show the last banners straight away, even offline.
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let payload = try? JSONDecoder().decode(Payload.self, from: data) {
            banners = payload.banners
        }
    }

    /// Fetches the current banners. A failed request keeps whatever is shown.
    func refresh() async {
        var request = URLRequest(url: Self.endpoint)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        banners = payload.banners
        UserDefaults.standard.set(data, forKey: cacheKey)
        // Download the logos now, in parallel, so the cards never wait for them.
        await withTaskGroup(of: Void.self) { group in
            for banner in payload.banners {
                group.addTask { _ = await BannerImageCache.shared.load(banner.logo) }
            }
        }
    }
}
