import Foundation

/// Lenient Base64 decoding for share links and subscriptions (URL-safe alphabet, missing padding).
enum Base64Codec {
    static func decode(_ text: String) -> Data? {
        var normalized = text
            .filter { !$0.isWhitespace }
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while normalized.count % 4 != 0 {
            normalized.append("=")
        }
        guard !normalized.isEmpty else { return nil }
        return Data(base64Encoded: normalized)
    }

    static func decodeToString(_ text: String) -> String? {
        guard let data = decode(text) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
