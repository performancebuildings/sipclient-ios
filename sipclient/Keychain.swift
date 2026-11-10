import Foundation
import Security

/// Every item uses the after-first-unlock class, because a push must read them on a locked phone.
enum Keychain {
    enum Item: String {
        case link = "sip-details"
        case authState = "auth-state"
        /// The tenant the session belongs to. Stored and cleared with `authState`.
        case tenant = "tenant"
        case deviceId = "device-id"
        /// The POC's password, only ever deleted now.
        case pocPassword = "sip-password"
    }

    private static let service = Bundle.main.bundleIdentifier!

    /// True before the first unlock after a restart, when a failed read doesn't mean "not stored".
    static var isLocked: Bool {
        var result: CFTypeRef?
        return SecItemCopyMatching(readQuery(.deviceId) as CFDictionary, &result) == errSecInteractionNotAllowed
    }

    static func data(_ item: Item) -> Data? {
        var result: CFTypeRef?
        guard SecItemCopyMatching(readQuery(item) as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func set(_ data: Data, for item: Item) {
        delete(item)
        var attributes = query(item)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess { print("Keychain: save failed (\(status))") }
    }

    static func delete(_ item: Item) {
        SecItemDelete(query(item) as CFDictionary)
    }

    private static func query(_ item: Item) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue,
        ]
    }

    private static func readQuery(_ item: Item) -> [String: Any] {
        var query = query(item)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }
}
