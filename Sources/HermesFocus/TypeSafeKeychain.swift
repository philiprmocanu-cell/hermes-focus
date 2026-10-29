import Foundation
import FocusCore
import Security

/// One key in the login Keychain (service "app.hermesfocus.mac"): never UserDefaults, never a log line.
struct KeychainSlot: Sendable {
    let account: String

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: TypeSafeKeyField.keychainService,
         kSecAttrAccount as String: account]
    }

    func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    var hasKey: Bool { read() != nil }

    @discardableResult
    func save(_ key: String) -> Bool {
        let data = Data(key.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else {
            log.error("\(account, privacy: .public): keychain update failed (\(update))")
            return false
        }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let st = SecItemAdd(add as CFDictionary, nil)
        if st != errSecSuccess { log.error("\(account, privacy: .public): keychain add failed (\(st))") }
        return st == errSecSuccess
    }

    func remove() {
        let st = SecItemDelete(query as CFDictionary)
        if st != errSecSuccess && st != errSecItemNotFound { log.error("\(account, privacy: .public): keychain delete failed (\(st))") }
    }
}

/// The TypeSafe key on this Mac (account "typesafe_key"). A friend's brain keeps its own copy; this one lets the
/// app show "set" and send it again if the server ever loses it. In local mode it is the only copy: the local
/// brain reads it from here on every call.
enum TypeSafeKeychain {
    static let slot = KeychainSlot(account: TypeSafeKeyField.keychainAccount)
    static func read() -> String? { slot.read() }
    static var hasKey: Bool { slot.hasKey }
    @discardableResult static func save(_ key: String) -> Bool { slot.save(key) }
    static func remove() { slot.remove() }
}

/// Local mode's optional Anthropic key (account "anthropic_key").
enum AnthropicKeychain {
    static let slot = KeychainSlot(account: AnthropicKeyField.keychainAccount)
    static func read() -> String? { slot.read() }
    static var hasKey: Bool { slot.hasKey }
    @discardableResult static func save(_ key: String) -> Bool { slot.save(key) }
    static func remove() { slot.remove() }
}

/// The keys the local brain asks for on every call, read from the Keychain once and kept until a key changes
/// (a Keychain read every second during work would be wasteful). Thread-safe: the brain asks from any task.
final class LocalKeys: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: LocalBrain.Keys?

    func current() -> LocalBrain.Keys {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let k = LocalBrain.Keys(typesafe: TypeSafeKeychain.read() ?? "", anthropic: AnthropicKeychain.read() ?? "",
                                model: AnthropicKeyField.model(stored: UserDefaults.standard.string(forKey: BrainMode.anthropicModelKey)))
        cached = k
        return k
    }

    /// A key was saved or removed: read the Keychain again on the next call.
    func invalidate() {
        lock.lock(); cached = nil; lock.unlock()
    }
}
