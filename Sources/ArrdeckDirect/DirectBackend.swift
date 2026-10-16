import ArrdeckData
import Foundation

/// What answers the screens: the domain answers the arrdeck server's API gave
/// the web app, worked out on the device by asking Sonarr, Radarr,
/// qBittorrent and the rest directly. The server's Python (the pinned
/// submodule) is the reference for each answer; what only a server can do
/// (push, feeds for other apps, sampling while nobody looks) has no place in
/// the app.
///
/// One conformance per file (`DirectBackend+Dashboard.swift` and so on), each
/// following the server module it ports.
public final class DirectBackend: Sendable {
    public let registry: Registry
    let readingStore: any ReadingStore
    let cache = BlockCache()

    public init(registry: Registry, reading: any ReadingStore = InMemoryReadingStore()) {
        self.registry = registry
        readingStore = reading
    }

    public convenience init(profileID: UUID) {
        self.init(
            registry: Registry(store: KeychainConnectionStore(profileID: profileID)),
            reading: DefaultsReadingStore(profileID: profileID)
        )
    }

    /// Runs a request on behalf of a screen, putting a service's failure in
    /// the words the screens show: a refused key is the service's problem,
    /// and says so.
    func call<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as APIError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw APIError.refused(Self.reason(error))
        }
    }
}

extension DirectBackend: Backend {}
