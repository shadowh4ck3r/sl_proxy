import CryptoKit
import UIKit

/// Memory + disk cache for banner logos. The banners are prefetched as soon as the list arrives
/// and kept on disk, so the logo shows instantly on the next launch instead of flashing a
/// placeholder while AsyncImage downloads it.
final class BannerImageCache {
    static let shared = BannerImageCache()

    private let memory = NSCache<NSString, UIImage>()
    private let folder: URL
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        folder = base.appendingPathComponent("BannerLogos", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func file(for urlString: String) -> URL {
        let digest = SHA256.hash(data: Data(urlString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(name)
    }

    /// Instant lookup (memory, then disk). Nil when the logo has never been downloaded.
    func cached(_ urlString: String) -> UIImage? {
        if let image = memory.object(forKey: urlString as NSString) { return image }
        guard let data = try? Data(contentsOf: file(for: urlString)), let image = UIImage(data: data) else {
            return nil
        }
        memory.setObject(image, forKey: urlString as NSString)
        return image
    }

    /// Cached image, or a download (http / https only) that is then cached.
    func load(_ urlString: String) async -> UIImage? {
        if let image = cached(urlString) { return image }
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = UIImage(data: data) else { return nil }
        memory.setObject(image, forKey: urlString as NSString)
        try? data.write(to: file(for: urlString), options: .atomic)
        return image
    }
}
