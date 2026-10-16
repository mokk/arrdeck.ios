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

/// Profiles as one JSON blob in the Keychain, beside each profile's service
/// keys, rather than in UserDefaults.
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
        return try Self.decode(data)
    }

    /// Profiles as stored, by this build or an older one. Older builds also
    /// kept profiles for an arrdeck server, at its address; the app no longer
    /// talks to one, so those are left out. Theirs was a `baseURL` naming the
    /// server, where a profile of the services themselves named only itself.
    static func decode(_ data: Data) throws -> [ServerProfile] {
        struct Stored: Decodable {
            let id: UUID
            let name: String
            let baseURL: URL?
        }
        return try JSONDecoder().decode([Stored].self, from: data)
            .filter { $0.baseURL == nil || $0.baseURL?.scheme == "arrdeck-direct" }
            .map { ServerProfile(id: $0.id, name: $0.name) }
    }

    public func save(_ profiles: [ServerProfile]) throws {
        let data = try JSONEncoder().encode(profiles)
        // Delete-then-add instead of update: simpler, and the blob is small
        // enough that atomicity across the pair does not matter — a crash
        // between the two loses profiles the user re-adds, not credentials.
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        // Readable after first unlock, as the connections are: Siri asks with
        // the phone locked.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }
}
