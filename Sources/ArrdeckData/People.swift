import ArrdeckAPI
import Foundation

public typealias Person = Components.Schemas.PersonOut
public typealias PersonMovie = Components.Schemas.PersonMovieOut

/// A person from a film's credits, as a navigation value.
public struct PersonRef: Hashable, Sendable {
    public let tmdbID: Int
    public init(_ tmdbID: Int) { self.tmdbID = tmdbID }
}

/// Their films in the library, and — when Overseerr is configured — the
/// released ones that are not.
public protocol PeopleAPI: Sendable {
    func person(_ tmdbID: Int) async throws -> Person
}

extension LiveAPI: PeopleAPI {
    public func person(_ tmdbID: Int) async throws -> Person {
        try await call {
            switch try await client.person_api_v1_library_people__tmdb_id__get(path: .init(tmdb_id: tmdbID)) {
            case let .ok(ok): try ok.body.json
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }
}

/// Where a title sits in the list it was opened from, for next and previous.
public enum TitleSequence {
    public static func neighbours(of ref: MediaRef, in refs: [MediaRef]) -> (previous: MediaRef?, next: MediaRef?) {
        guard let i = refs.firstIndex(of: ref) else { return (nil, nil) }
        return (i > 0 ? refs[i - 1] : nil, i + 1 < refs.count ? refs[i + 1] : nil)
    }
}
