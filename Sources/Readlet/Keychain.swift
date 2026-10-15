import Foundation
import Security

/// Secrets (API keys) live in the login Keychain, not in preferences.
/// Accounts: "gateway" (main model gateway), "tts" (speech provider).
enum Keychain {
    static let service = "io.novarock.readit"

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// empty value deletes the item; returns false when the Keychain refused the write
    @discardableResult
    static func set(_ value: String, _ account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if value.isEmpty { return delete(account) }
        let data = Data(value.utf8)
        let st = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if st == errSecSuccess { return true }
        guard st == errSecItemNotFound else { return false }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Readlet — \(account) API key"
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete(_ account: String) -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let st = SecItemDelete(q as CFDictionary)
        return st == errSecSuccess || st == errSecItemNotFound
    }

    /// Keychain lookups can prompt and are not free: cache per process, invalidated on write.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String] = [:]
    static func cached(_ account: String) -> String? {
        lock.lock(); if let v = cache[account] { lock.unlock(); return v.isEmpty ? nil : v }; lock.unlock()
        let v = get(account) ?? ""
        lock.lock(); cache[account] = v; lock.unlock()
        return v.isEmpty ? nil : v
    }
    @discardableResult
    static func store(_ value: String, _ account: String) -> Bool {
        let ok = set(value, account)
        lock.lock(); cache[account] = ok ? value : nil; lock.unlock()
        return ok
    }
}
