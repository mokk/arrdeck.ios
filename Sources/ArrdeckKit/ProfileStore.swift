import Foundation
import Security

/// Where profiles live. A protocol so the views and tests use an in-memory
/// store and only the device touches the Keychain.
public protocol ProfileStore: Sendable {
    func load() throws -> [ServerProfile]
    func save(_ profiles: [ServerProfile]) throws
}

public final class InMemoryProfileStore: ProfileStore, @unchecked Sendable {
    private var profiles: [ServerProfile] = []
    private let lock = NSLock()

    public init() {}

    public func load() throws -> [ServerProfile] {
        lock.withLock { profiles }
    }

    public func save(_ profiles: [ServerProfile]) throws {
        lock.withLock { self.profiles = profiles }
    }
}

/// Profiles as one JSON blob in the Keychain rather than UserDefaults: a base
/// URL names where a session cookie is valid, which is worth device-encryption
/// and exclusion from unencrypted backups.
public struct KeychainProfileStore: ProfileStore {
    let service: String

    public init(service: String = "dk.thrawn.arrdeck.profiles") {
        self.service = service
    }

    public enum KeychainError: Error {
        case status(OSStatus)
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "profiles",
        ]
    }

    public func load() throws -> [ServerProfile] {
        var attributes = query
        attributes[kSecReturnData as String] = true
        var result: AnyObject?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.status(status)
        }
        return try JSONDecoder().decode([ServerProfile].self, from: data)
    }

    public func save(_ profiles: [ServerProfile]) throws {
        let data = try JSONEncoder().encode(profiles)
        // Delete-then-add instead of update: simpler, and the blob is small
        // enough that atomicity across the pair does not matter — a crash
        // between the two loses profiles the user re-adds, not credentials.
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        // Readable after first unlock so a background push handler can resolve
        // which profile a notification belongs to.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }
}
