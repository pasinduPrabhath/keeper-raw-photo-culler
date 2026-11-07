import Foundation
import Security

/// Tiny wrapper over the macOS Keychain for OAuth tokens and the client secret.
public enum Keychain {
    static let service = "dev.keeper.Keeper"

    public static func set(_ value: Data, account: String) {
        delete(account: account)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: value,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    public static func get(account: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    public static func delete(account: String) {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        SecItemDelete(query as CFDictionary)
    }

    public static func setString(_ value: String, account: String) { set(Data(value.utf8), account: account) }
    public static func getString(account: String) -> String? { get(account: account).flatMap { String(data: $0, encoding: .utf8) } }
}
