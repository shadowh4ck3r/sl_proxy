import Foundation

/// Exit IP and country of the running connection, shown on Home as a flag plus a masked IP (V2Box
/// shows the same in its status row). The lookup goes through the local proxy listener, so it
/// reports where the traffic really leaves the network: the upstream server in Rule / Global mode,
/// your own connection in Direct mode.
@MainActor
final class ExitIPStore: ObservableObject {
    struct Info: Equatable {
        let ip: String
        let countryCode: String
        let country: String

        /// Regional-indicator emoji built from the ISO country code ("US" gives the US flag).
        var flag: String {
            countryCode.uppercased().unicodeScalars
                .compactMap { UnicodeScalar(127_397 + $0.value) }
                .map { String($0) }
                .joined()
        }

        var maskedIP: String { ip.masked }
    }

    @Published private(set) var info: Info?

    func clear() {
        info = nil
    }

    /// `endpoint` is the "host:port" of the loopback listener. A failed lookup leaves no flag.
    func refresh(endpoint: String) async {
        guard let port = Int(String(endpoint.split(separator: ":").last ?? "")) else { return }
        info = await Self.fetch(port: port)
    }

    nonisolated private static func fetch(port: Int) async -> Info? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": port,
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": port,
        ]
        configuration.timeoutIntervalForRequest = 8
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        guard let url = URL(string: "https://ipwho.is/?fields=success,ip,country,country_code") else { return nil }
        do {
            let (data, _) = try await session.data(from: url)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (object["success"] as? Bool) ?? true,
                  let ip = object["ip"] as? String,
                  let code = object["country_code"] as? String, code.count == 2 else { return nil }
            return Info(ip: ip, countryCode: code, country: (object["country"] as? String) ?? code)
        } catch {
            return nil
        }
    }
}
