import Foundation
import Security

/// The backend session token in the Keychain. The password is never stored.
public enum BackendKeychain {
    private static func query() -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "com.niklasarnitz.opengarmin.backend",
            kSecAttrAccount: "token",
        ]
    }

    public static func token() -> String? {
        var query = query()
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    public static func saveToken(_ token: String) throws {
        let data = Data(token.utf8)
        var status = SecItemUpdate(query() as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query()
            add[kSecValueData] = data
            add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw BackendError.keychain(status) }
    }

    public static func deleteToken() {
        SecItemDelete(query() as CFDictionary)
    }
}
