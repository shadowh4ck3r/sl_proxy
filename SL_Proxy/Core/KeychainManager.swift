import Foundation
import Security

/// Thin wrapper over the iOS Keychain (`kSecClassGenericPassword`) for the SailorsLoot account
/// token. Tokens and credentials never go into UserDefaults.
///
/// Items use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: readable by the background engine
/// after the first unlock, never synced to iCloud Keychain and never restored onto another device.
enum KeychainManager {
    private static let service = "com.slproxy.sailorsloot-account"

    enum Key {
        static let token = "api.token"
        static let username = "api.username"
    }

    private static func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    @discardableResult
    static func set(_ value: String, for key: String) -> Bool {
        SecItemDelete(baseQuery(key) as CFDictionary)
        var query = baseQuery(key)
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func get(_ key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(_ key: String) -> Bool {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
