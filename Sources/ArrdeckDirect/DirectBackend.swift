import ArrdeckData
import ArrdeckKit
import Foundation

/// What the arrdeck server did, done on the device: the same domain answers
/// the screens get from `LiveAPI`, worked out by asking Sonarr, Radarr,
/// qBittorrent and the rest directly. The server's Python is the reference
/// for each answer; what only a server can do (push, feeds for other apps,
/// sampling while nobody looks) is left out, and its screens with it.
///
/// One conformance per file (`DirectBackend+Dashboard.swift` and so on), each
/// following the server module it ports.
public final class DirectBackend: Sendable {
    public let registry: Registry
    let cache = BlockCache()

    public init(registry: Registry) {
        self.registry = registry
    }

    public convenience init(profileID: UUID) {
        self.init(registry: Registry(store: KeychainConnectionStore(profileID: profileID)))
    }

    /// What this build can do without a server, in the server's feature
    /// names. The screens gate on these the way they do on a server's
    /// /about, so whatever is not listed simply does not show.
    public static let features: Set<Feature> = [
        .diagnose, .credits, .qualityProfiles, .scheduledTasks, .arrBackups, .blocklist, .popular, .calendar,
        .wanted, .books, .interactiveSearch, .subtitles, .vpn,
    ]

    public static var info: BackendInfo {
        BackendInfo(version: "direct", features: Set(features.map(\.rawValue)))
    }

    /// Runs a request on behalf of a screen, putting a service's failure in
    /// the words the screens show. Never `.unauthorized`: that means "sign in
    /// to arrdeck again", and there is no arrdeck to sign in to — a refused
    /// key is the service's problem, and says so.
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
