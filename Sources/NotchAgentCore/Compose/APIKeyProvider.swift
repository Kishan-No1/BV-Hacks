// Where the Anthropic API key comes from: the environment first, then the Keychain.
// The key is never logged, printed or put into an error. Keychain errors carry an OSStatus only.
import Foundation
import Security

public struct APIKeyProvider: Sendable {
    public var env: @Sendable () -> String?
    public var keychain: @Sendable () -> String?

    public init(env: @escaping @Sendable () -> String?, keychain: @escaping @Sendable () -> String?) {
        self.env = env
        self.keychain = keychain
    }

    /// ANTHROPIC_API_KEY from the environment first, then the Keychain. Trimmed; empty counts as missing.
    public func key() -> String? {
        Self.clean(env()) ?? Self.clean(keychain())
    }

    public static let keychainService = "notchAgent"
    /// The service name from before the app was renamed (Nod). Read as a fallback, removed on save or delete.
    public static let legacyKeychainService = "Nod"
    public static let keychainAccount = "anthropic-api-key"

    public static let live = APIKeyProvider(
        env: { ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] },
        keychain: { readFromKeychain(service: keychainService) ?? readFromKeychain(service: legacyKeychainService) }
    )

    public enum KeychainError: Error, Equatable, Sendable {
        /// Nothing to store: the key was empty after trimming.
        case emptyKey
        /// A Security framework call failed with this status.
        case status(OSStatus)
    }

    /// Stores (replaces) the key as a generic password. Used by the app's "Set Anthropic API key…" menu item.
    public static func saveToKeychain(_ key: String) throws {
        guard let key = clean(key) else { throw KeychainError.emptyKey }
        deleteFromKeychain()
        var item = query(service: keychainService)
        item[kSecValueData as String] = Data(key.utf8)
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public static func deleteFromKeychain() {
        SecItemDelete(query(service: keychainService) as CFDictionary)
        SecItemDelete(query(service: legacyKeychainService) as CFDictionary)
    }

    // MARK: Helpers

    private static func query(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keychainAccount,
        ]
    }

    private static func readFromKeychain(service: String) -> String? {
        var q = query(service: service)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
