import Foundation

/// One set of services the app knows about: their addresses and keys are kept
/// on the device (in the Keychain, per profile id), and the app talks to each
/// service itself.
public struct ServerProfile: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}
