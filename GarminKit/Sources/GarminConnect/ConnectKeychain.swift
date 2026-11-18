import Foundation
import Security

/// The Garmin Connect tokens in the Keychain. The password is never stored.
enum ConnectKeychain {
    private static func query() -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "com.niklasarnitz.opengarmin.connect",
            kSecAttrAccount: "tokens",
        ]
    }

    static func load() -> ConnectCredentials? {
        var query = query()
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(ConnectCredentials.self, from: data)
    }

    static func save(_ credentials: ConnectCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        var status = SecItemUpdate(query() as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query()
            add[kSecValueData] = data
            add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw GarminConnectError.keychain(status) }
    }

    static func delete() {
        SecItemDelete(query() as CFDictionary)
    }
}
