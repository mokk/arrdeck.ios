import ArrdeckData
import Foundation

/// What the Add screen's answers share: which titles the library already
/// holds, so a search result can say so and be edited in place. Ported from
/// discover.py's `_library_map` and musicsearch.py's `music_library_map`.
enum Catalog {
    /// One title the library holds, as a search result carries it.
    struct Held: Sendable, Equatable {
        var libraryID: Int
        var monitored: Bool
        var qualityProfile: Int?
        var hasFile: Bool
        /// Music only: the library artist's own picture, for a search result
        /// Lidarr hands back without one.
        var poster: String?
    }

    /// A search result, badged with what the library has of it: the
    /// server's `in_library=… , **library.get(id, {})`.
    static func result(_ result: SearchResult, held: Held?) -> SearchResult {
        var result = result
        // the server always sends the list, empty for anything but a book
        if result.editions == nil { result.editions = [] }
        guard let held else {
            result.in_library = false
            return result
        }
        result.in_library = true
        result.library_id = held.libraryID
        result.monitored = held.monitored
        result.quality_profile_id = held.qualityProfile
        result.has_file = held.hasFile
        return result
    }

    /// Readarr's foreign ids are digits in a string; anything else is no id.
    static func numeric(_ value: JSON) -> Int? {
        guard let raw = value.string, !raw.isEmpty, raw.allSatisfy(\.isASCII), raw.allSatisfy(\.isNumber) else {
            return nil
        }
        return Int(raw)
    }
}

extension KeyedClient {
    /// Readarr's and Lidarr's combined search: author or artist entries and
    /// book or album ones, each with what adding needs. A fresh term sends
    /// the arr to its metadata server for every hit, which can take over a
    /// minute.
    func combinedSearch(_ term: String) async throws -> [JSON] {
        try await get("/search", query: ["term": term], timeout: 90).array
    }

    /// The metadata profile a new author or artist gets: the one picked, else
    /// the arr's first.
    func metadataProfile(_ chosen: Int?) async throws -> Int? {
        if let chosen { return chosen }
        return try await get("/metadataprofile").array.first?["id"].int
    }
}
