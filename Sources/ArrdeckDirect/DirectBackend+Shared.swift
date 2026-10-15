import Foundation

/// Pieces several screens' answers share: artwork addresses and ratings,
/// ported from the server's posters.py, discover.py and music.py.
enum Artwork {
    /// TMDB sizes the app asks for. The arrs hand out /original (~220 KB a
    /// poster); a list needs a fraction of that.
    static let posterSize = "w500"
    static let headshotSize = "w185"
    static let backdropSize = "w1280"
    static let allowedSizes: Set = [posterSize, headshotSize, backdropSize]

    /// A TMDB address at a size the app allows: the one asked for, the one it
    /// already has when that is allowed, the poster size otherwise. Other
    /// hosts are left as they are.
    static func normalise(_ url: String, size: String? = nil) -> String {
        let prefix = "https://image.tmdb.org/t/p/"
        guard url.hasPrefix(prefix) else { return url }
        let rest = url.dropFirst(prefix.count)
        guard let slash = rest.firstIndex(of: "/") else { return url }
        let current = String(rest[..<slash])
        let chosen = size ?? (allowedSizes.contains(current) ? current : posterSize)
        return prefix + chosen + rest[slash...]
    }

    /// The first image of a kind with an address the device can load as is.
    /// Where the server proxied artwork through itself, the app fetches it
    /// straight from the CDN.
    static func image(_ images: JSON, kind: String, size: String? = nil) -> String? {
        for image in images.array where image["coverType"].string == kind {
            let url = image["remoteUrl"].string ?? image["url"].string ?? ""
            if url.hasPrefix("http://") || url.hasPrefix("https://") { return normalise(url, size: size) }
        }
        return nil
    }

    static func poster(_ images: JSON) -> String? { image(images, kind: "poster") }

    static func fanart(_ images: JSON) -> String? { image(images, kind: "fanart", size: backdropSize) }

    /// Readarr calls the poster a cover. The first image of either kind
    /// decides, as books.py's `book_cover` has it; only an address the
    /// device can load as is counts.
    static func bookCover(_ images: JSON) -> String? {
        guard let image = images.array.first(where: { ["cover", "poster"].contains($0["coverType"].string ?? "") })
        else { return nil }
        let url = image["remoteUrl"].string ?? image["url"].string ?? ""
        return url.hasPrefix("http://") || url.hasPrefix("https://") ? normalise(url) : nil
    }

    /// Overseerr hands out bare TMDB paths. The server asked for w342 and its
    /// proxy clamped that to the poster size; `normalise` does the same.
    static func tmdbPoster(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return normalise("https://image.tmdb.org/t/p/w342" + path)
    }

    /// An album's cover, or a looked-up artist's poster.
    static func musicCover(_ images: JSON, kinds: [String] = ["cover", "poster"]) -> String? {
        for kind in kinds {
            if let url = image(images, kind: kind) { return url }
        }
        return nil
    }
}

enum Ratings {
    /// One number for a card: Radarr carries several sources, Sonarr a
    /// single one; IMDb first.
    static func headline(_ ratings: JSON) -> Double? {
        if let value = ratings["value"].double { return value == 0 ? nil : value }
        for source in ["imdb", "tmdb"] {
            if let value = ratings[source]["value"].double, value != 0 { return value }
        }
        return nil
    }

    /// Lidarr's single score, out of 10. It sends 0 when there are no votes.
    static func music(_ item: JSON) -> Double? {
        let ratings = item["ratings"]
        guard let value = ratings["value"].double, value != 0, (ratings["votes"].int ?? 0) > 0 else { return nil }
        return value
    }
}

/// What the dashboard, the watched map and the statistics read of Plex alike
/// (plex.py, watchstats.py).
enum Plex {
    /// A key Plex sends as text or as a number.
    static func key(_ value: JSON) -> String? {
        value.string ?? value.int.map(String.init)
    }

    /// The server's own id, "" when it cannot be had: without it a row
    /// simply cannot open in Plex.
    static func machine(_ plex: KeyedClient) async -> String {
        (try? await plex.get("/identity"))?["MediaContainer"]["machineIdentifier"].string ?? ""
    }

    /// Where Plex's web app opens one of this server's items, less the item's
    /// rating key.
    static func detailsBase(machine: String) -> String {
        "https://app.plex.tv/desktop/#!/server/\(machine)/details?key=/library/metadata/"
    }

    /// The movie and show sections: what is watched, not music or photos.
    static func sections(_ plex: KeyedClient) async throws -> [JSON] {
        try await plex.get("/library/sections")["MediaContainer"]["Directory"].array
            .filter { ["movie", "show"].contains($0["type"].string ?? "") }
    }

    /// Everything in a section. includeGuids gives the imdb/tmdb/tvdb ids
    /// inline, which is what lets this join the arrs without a lookup per
    /// title.
    static func items(_ plex: KeyedClient, in section: JSON) async throws -> [JSON] {
        let key = Self.key(section["key"]) ?? ""
        return try await plex.get("/library/sections/\(key)/all", query: ["includeGuids": "1"], timeout: 30)[
            "MediaContainer"]["Metadata"].array
    }
}

extension DirectBackend {
    /// Lidarr's own copy of a library artist's picture: an address under
    /// Lidarr carrying the key, since the image loader cannot send a header.
    func lidarrImage(_ artist: JSON, kind: String = "poster", size: String? = "250") -> String? {
        if let remote = Artwork.musicCover(artist["images"], kinds: [kind]) { return remote }
        guard let id = artist["id"].int, artist["images"].array.contains(where: { $0["coverType"].string == kind }),
              let lidarr = try? registry.arr("lidarr")
        else { return nil }
        let name = size != nil && kind == "poster" ? "\(kind)-\(size!).jpg" : "\(kind).jpg"
        return lidarr.url("/mediacover/artist/\(id)/\(name)", query: ["apikey": registry.connection("lidarr").apiKey])
            .absoluteString
    }

    /// The year of a Lidarr date, when it is a real one: Lidarr's "no date"
    /// is 0001-01-01.
    static func year(_ date: JSON) -> Int? {
        date.year.flatMap { $0 > 1 ? $0 : nil }
    }
}
