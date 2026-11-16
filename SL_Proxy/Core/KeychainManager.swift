import Foundation
import Security

/// Everything the app keeps about the signed-in sailorsloot.xyz account lives in the Keychain
/// (`kSecClassGenericPassword`), never in UserDefaults or a plain file. The Bearer token is stored
/// together with its expiry and the username as one encoded item.
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: readable by background refreshes after the
/// first unlock, never synced to iCloud Keychain and never restored onto another device.
enum KeychainManager {
    struct Session: Codable, Equatable {
        var token: String
        var username: String
        var expiresAt: Date?

        var isExpired: Bool {
            guard let expiresAt else { return false }
            return expiresAt <= Date()
        }
    }

    enum KeychainError: Error { case unexpectedStatus(OSStatus) }

    private static let service = "xyz.sailorsloot.slproxy.account"
    private static let sessionAccount = "api-session"

    // MARK: - Session (token + username + expiry)

    static func saveSession(_ session: Session) throws {
        let data = try JSONEncoder().encode(session)
        try save(data, account: sessionAccount)
    }

    static func loadSession() -> Session? {
        guard let data = read(account: sessionAccount) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    static func deleteSession() {
        delete(account: sessionAccount)
    }

    // MARK: - Generic password items

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func save(_ data: Data, account: String) throws {
        var query = baseQuery(account: account)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    static func read(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }
}
