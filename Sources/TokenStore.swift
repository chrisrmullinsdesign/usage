import Foundation
import Security

/// A token the person pasted in themselves, kept in this app's own Keychain item.
///
/// Separate from Claude Code's `Claude Code-credentials` in every way that matters: a
/// different service name, created and owned by this app, and never written back to
/// Claude Code's item. Nothing here can affect a Claude Code login.
///
/// This uses the Security framework rather than the `security` CLI that `Credentials`
/// uses for reading. Writing through the CLI would mean `security add-generic-password
/// -w <token>`, putting the token in the process arguments, where any other process on
/// the Mac could read it out of `ps`.
enum TokenStore {
    private static let service = "ClaudeUsage manual token"
    private static let account = "oauth-access-token"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// nil when nothing has been stored, so callers fall back to Claude Code's login.
    static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else { return nil }
        return token
    }

    static func save(_ token: String) throws {
        guard let data = token.data(using: .utf8) else { throw StoreError.encoding }

        // Update in place when an item already exists; SecItemAdd would fail with
        // errSecDuplicateItem rather than overwrite.
        let updated = SecItemUpdate(baseQuery as CFDictionary,
                                    [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw StoreError.keychain(updated) }

        var query = baseQuery
        query[kSecValueData as String] = data
        // Only readable while the Mac is unlocked, and never synced to iCloud Keychain:
        // this token belongs to one machine and shouldn't travel.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        query[kSecAttrSynchronizable as String] = false
        query[kSecAttrLabel as String] = "Claude Usage — pasted token"

        let added = SecItemAdd(query as CFDictionary, nil)
        guard added == errSecSuccess else { throw StoreError.keychain(added) }
    }

    /// Removing a token that isn't there is success, not an error: the caller wanted it gone.
    static func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.keychain(status)
        }
    }

    enum StoreError: LocalizedError {
        case encoding
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .encoding:
                "That token contains characters the Keychain can't store."
            case .keychain(let status):
                "The Keychain refused to store the token: "
                    + (SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)")
            }
        }
    }
}
