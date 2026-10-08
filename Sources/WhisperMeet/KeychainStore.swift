import Foundation
import Security

/// Minimal Keychain wrapper for a single secret (the Claude API key). Keeping the
/// key in the Keychain rather than UserDefaults avoids storing it in plain text.
enum KeychainStore {
    private static let service = "com.whispermeet.app"

    static func string(for account: String) -> String? {
        guard TestProcess.allowsRealAccess(to: "Keychain read") else { return nil }
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func set(_ value: String?, for account: String) -> Bool {
        guard TestProcess.allowsRealAccess(to: "Keychain write") else { return false }
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return delete(account: account) }

        let query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(trimmed.utf8)
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = Data(trimmed.utf8)
            return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        guard TestProcess.allowsRealAccess(to: "Keychain delete") else { return false }
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

/// Where `AppModel` reads and writes the Claude API key (F442). The Keychain in the app; a test that needs
/// a key present, or wants to watch what is written, hands in `inMemory` instead of reaching the login
/// Keychain. (A test that hands in nothing does not reach it either: `KeychainStore` refuses in a test
/// process. See `TestProcess`.)
struct ClaudeKeyStore: Sendable {
    static let account = "claudeAPIKey"

    var read: @Sendable () -> String?
    var write: @Sendable (String?) -> Void

    static let keychain = ClaudeKeyStore(
        read: { KeychainStore.string(for: ClaudeKeyStore.account) },
        write: { KeychainStore.set($0, for: ClaudeKeyStore.account) }
    )

    /// A store that lives and dies with the value, never leaving the process. `write` follows the
    /// Keychain wrapper's rule: a blank or whitespace-only key deletes.
    static func inMemory(_ key: String? = nil) -> ClaudeKeyStore {
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var key: String?
            init(_ key: String?) { self.key = key }
            func get() -> String? { lock.withLock { key } }
            func set(_ value: String?) {
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                lock.withLock { key = (trimmed?.isEmpty ?? true) ? nil : trimmed }
            }
        }
        let box = Box(key)
        return ClaudeKeyStore(read: { box.get() }, write: { box.set($0) })
    }
}
