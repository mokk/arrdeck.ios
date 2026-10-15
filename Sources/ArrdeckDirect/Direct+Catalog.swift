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

    /// Overseerr hands out bare TMDB paths. The server asked for w342 and its
    /// proxy clamped that to the poster size; `normalise` does the same.
    static func tmdbPoster(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return Artwork.normalise("https://image.tmdb.org/t/p/w342" + path)
    }

    /// Text, with an empty string as missing — Python's `value or fallback`.
    static func text(_ value: JSON) -> String? {
        guard let raw = value.string, !raw.isEmpty else { return nil }
        return raw
    }

    /// The year at the front of a date the services write as text.
    static func leadingYear(_ date: JSON) -> Int? {
        guard let raw = date.string, raw.count >= 4, let year = Int(raw.prefix(4)) else { return nil }
        return year
    }

    /// Readarr's foreign ids are digits in a string; anything else is no id.
    static func numeric(_ value: JSON) -> Int? {
        guard let raw = value.string, !raw.isEmpty, raw.allSatisfy(\.isASCII), raw.allSatisfy(\.isNumber) else {
            return nil
        }
        return Int(raw)
    }
}

extension DirectBackend {
    /// What the server's `cache.set(key, None)` did after a write: the next
    /// read of these keys fetches afresh.
    func catalogForget(_ keys: String...) {
        cache.remove(keys)
    }
}
