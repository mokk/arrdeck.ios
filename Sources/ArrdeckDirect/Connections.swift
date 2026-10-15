import Foundation
import Security

/// Where one service lives and how to get in: what the server kept in its
/// service_settings table, kept on the device instead.
public struct ServiceConnection: Codable, Hashable, Sendable {
    public var url: String
    public var apiKey: String
    public var username: String
    public var password: String

    public init(url: String = "", apiKey: String = "", username: String = "", password: String = "") {
        self.url = url
        self.apiKey = apiKey
        self.username = username
        self.password = password
    }

    /// Trimmed the way the server saved them: no trailing slash on the
    /// address, no stray whitespace around the key. The password is kept as
    /// typed.
    public var normalised: ServiceConnection {
        var url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }
        return ServiceConnection(
            url: url,
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password
        )
    }
}

/// The services a direct profile can be connected to, and what each needs
/// before it counts as set up. Mirrors the server's registry, less the parts
/// that only make sense on a server (its host helper).
public enum DirectServices {
    public static let all = [
        "radarr", "sonarr", "readarr", "lidarr", "prowlarr", "qbittorrent", "transmission",
        "overseerr", "gluetun", "bazarr", "plex", "prometheus", "trakt",
    ]

    static let needsAPIKey: Set = [
        "radarr", "sonarr", "readarr", "lidarr", "prowlarr", "overseerr", "gluetun", "bazarr", "plex",
    ]

    /// A fixed public address: the key is all they need.
    static let keyOnly: Set = ["trakt"]

    /// Listed only once set up, as the server does: builds that predate them
    /// decode the list as a fixed set.
    static let listedWhenConfigured: Set = ["lidarr"]

    /// The apps a title can be opened in, at the address the app talks to.
    static let webUI: Set = ["radarr", "sonarr", "readarr"]

    public static func isConfigured(_ name: String, _ connection: ServiceConnection?) -> Bool {
        guard let connection else { return false }
        if keyOnly.contains(name) { return !connection.apiKey.isEmpty }
        guard Endpoint(connection.url) != nil else { return false }
        return !(needsAPIKey.contains(name) && connection.apiKey.isEmpty)
    }

    static func listed(_ name: String, configured: Bool) -> Bool {
        configured || !listedWhenConfigured.contains(name)
    }
}

/// Where a direct profile's connections are kept. A protocol so tests and
/// previews use memory and only the device touches the Keychain.
public protocol ConnectionStore: Sendable {
    func load() throws -> [String: ServiceConnection]
    func save(_ connections: [String: ServiceConnection]) throws
}

public final class InMemoryConnectionStore: ConnectionStore, Sendable {
    private let connections: Locked<[String: ServiceConnection]>

    public init(_ connections: [String: ServiceConnection] = [:]) {
        self.connections = Locked(connections)
    }

    public func load() throws -> [String: ServiceConnection] { connections.current }

    public func save(_ connections: [String: ServiceConnection]) throws {
        self.connections.withLock { $0 = connections }
    }
}

/// One Keychain item per profile, holding every service's address and
/// credentials as JSON. API keys are full control of the arrs, so they get the
/// Keychain's encryption and stay out of unencrypted backups.
public struct KeychainConnectionStore: ConnectionStore {
    let profileID: UUID
    let service: String

    public init(profileID: UUID, service: String = "dk.thrawn.arrdeck.connections") {
        self.profileID = profileID
        self.service = service
    }

    public enum KeychainError: Error {
        case status(OSStatus)
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
        ]
    }

    public func load() throws -> [String: ServiceConnection] {
        var attributes = query
        attributes[kSecReturnData as String] = true
        var result: AnyObject?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return [:] }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.status(status)
        }
        return try JSONDecoder().decode([String: ServiceConnection].self, from: data)
    }

    public func save(_ connections: [String: ServiceConnection]) throws {
        let data = try JSONEncoder().encode(connections)
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        // Siri's answers run with the phone locked but unlocked once
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    /// When the profile itself is removed.
    public func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
