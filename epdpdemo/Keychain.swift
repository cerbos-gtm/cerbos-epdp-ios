import Foundation
import Security

/// Minimal Keychain wrapper for the demo's Hub client secret. Credentials must never be
/// hard-coded or stored in `UserDefaults`.
enum Keychain {
    static let clientSecretKey = "cerbos.hub.clientSecret"

    private static var service: String {
        Bundle.main.bundleIdentifier ?? "dev.cerbos.epdp.epdpdemo"
    }

    static func string(for key: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Replaces the stored value, or removes it when `value` is nil or empty. Returns the Keychain
    /// status so callers can tell the user when the secret was not persisted.
    @discardableResult
    static func set(_ value: String?, for key: String) -> OSStatus {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: key,
        ]
        let deleteStatus = SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty else {
            return deleteStatus == errSecItemNotFound ? errSecSuccess : deleteStatus
        }
        var attributes = query
        attributes[kSecValueData] = Data(value.utf8)
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    /// Human-readable description of a Keychain status, for error messages.
    static func message(for status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
    }
}
