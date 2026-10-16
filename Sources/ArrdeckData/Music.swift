import ArrdeckAPI
import Foundation
import Observation

public typealias LibraryArtist = Components.Schemas.LibraryArtistOut
public typealias LibraryAlbum = Components.Schemas.LibraryAlbumOut
public typealias ArtistDetail = Components.Schemas.ArtistDetailOut
public typealias AlbumDetail = Components.Schemas.AlbumDetailOut
public typealias AlbumTrack = Components.Schemas.AlbumTrackOut
public typealias AlbumMedium = Components.Schemas.AlbumMediumOut
public typealias MusicLink = Components.Schemas.MusicLinkOut

/// What an artist's albums monitor when Lidarr finds a new one.
public enum NewAlbums: String, CaseIterable, Sendable, Hashable {
    case all, new, none

    public var label: String {
        switch self {
        case .all: String(localized: "Monitor all")
        case .new: String(localized: "Monitor new")
        case .none: String(localized: "Do not monitor")
        }
    }
}

/// The artist settings Edit sends: only what changed, so an untouched field
/// never overwrites a change made in Lidarr meanwhile.
public struct ArtistChanges: Equatable, Sendable {
    public var monitored: Bool?
    public var monitorNewItems: NewAlbums?
    public var qualityProfile: Int?
    public var metadataProfile: Int?
    /// A new folder, and whether Lidarr moves the files there.
    public var path: String?
    public var moveFiles = false
    public var tags: [Int]?

    public init(monitored: Bool? = nil, monitorNewItems: NewAlbums? = nil, qualityProfile: Int? = nil,
                metadataProfile: Int? = nil, path: String? = nil, moveFiles: Bool = false, tags: [Int]? = nil) {
        self.monitored = monitored
        self.monitorNewItems = monitorNewItems
        self.qualityProfile = qualityProfile
        self.metadataProfile = metadataProfile
        self.path = path
        self.moveFiles = moveFiles
        self.tags = tags
    }

    /// The edit sheet's choices against the artist as loaded. A blank or
    /// unchanged folder is no move; tags compare as a set.
    public static func edit(
        _ artist: ArtistDetail, qualityProfile: Int?, metadataProfile: Int?, newAlbums: NewAlbums,
        path: String, moveFiles: Bool, tags: [Int]
    ) -> ArtistChanges {
        var changes = ArtistChanges()
        if let qualityProfile, qualityProfile != artist.quality_profile_id { changes.qualityProfile = qualityProfile }
        if let metadataProfile, metadataProfile != artist.metadata_profile_id { changes.metadataProfile = metadataProfile }
        if newAlbums.rawValue != artist.monitor_new_items { changes.monitorNewItems = newAlbums }
        let folder = path.trimmingCharacters(in: .whitespaces)
        if !folder.isEmpty, folder != artist.path {
            changes.path = folder
            changes.moveFiles = moveFiles
        }
        if Set(tags) != Set(artist.tags ?? []) { changes.tags = tags }
        return changes
    }

    public var isEmpty: Bool { self == ArtistChanges() }
}

/// Lidarr's library: the artists the Music tab shows, each one's albums and
/// settings, and an album's tracks and files.
public protocol MusicLibraryAPI: Sendable {
    /// Every artist, by Lidarr's own sort name.
    func libraryArtists() async throws -> [LibraryArtist]
    /// One artist's albums, EPs and singles, newest first.
    func artistAlbums(_ artistID: Int) async throws -> [LibraryAlbum]
    /// The artist with every album their metadata profile allows, monitored or not.
    func artistDetail(_ id: Int) async throws -> ArtistDetail
    func updateArtist(_ id: Int, _ changes: ArtistChanges) async throws
    /// Lidarr fetches the artist's albums and artwork again and rescans the folder.
    func refreshArtist(_ id: Int) async throws
    func albumDetail(_ id: Int) async throws -> AlbumDetail
    /// One track's file, or with no `file` every file of the album, from disk.
    func deleteAlbumFiles(album: Int, file: Int?) async throws
}

extension ImportTargetSearch {
    /// Artists in the server's order (Lidarr's sort name), filtered by name.
    public static func artists(_ artists: [LibraryArtist], query: String) -> [LibraryArtist] {
        Array(artists.filter { matches(query, $0.name) }.prefix(limit))
    }

    /// An artist's albums in the server's order, newest first, filtered by title.
    public static func albums(_ albums: [LibraryAlbum], query: String) -> [LibraryAlbum] {
        albums.filter { matches(query, $0.title) }
    }

    /// "Boards of Canada — Geogaddi", as the file row shows the pick.
    public static func albumLabel(artist: String, album: LibraryAlbum) -> String {
        let title = album.title ?? ""
        return artist.isEmpty ? title : "\(artist) — \(title)"
    }
}

// MARK: - What the artist and album screens share

public enum MusicLayout {
    /// Lidarr's primary album types, in the order its own artist page shows
    /// them; anything else follows under its own name, alphabetically.
    static let typeOrder = ["Album", "EP", "Single", "Broadcast", "Other"]

    public struct TypeGroup: Equatable, Sendable {
        public var type: String
        public var albums: [LibraryAlbum]

        /// "Albums", "EPs"… for the section heading; an unknown type as Lidarr names it.
        public var label: String {
            switch type {
            case "Album": String(localized: "Albums")
            case "EP": String(localized: "EPs")
            case "Single": String(localized: "Singles")
            case "Broadcast": String(localized: "Broadcasts")
            case "Other": String(localized: "Other")
            default: type
            }
        }
    }

    /// The artist's albums by type, each group in the server's order (newest first).
    public static func byType(_ albums: [LibraryAlbum]) -> [TypeGroup] {
        var groups: [String: [LibraryAlbum]] = [:]
        var seen: [String] = []
        for album in albums {
            let type = album.album_type.flatMap { $0.isEmpty ? nil : $0 } ?? "Other"
            if groups[type] == nil { seen.append(type) }
            groups[type, default: []].append(album)
        }
        func rank(_ type: String) -> Int { typeOrder.firstIndex(of: type) ?? typeOrder.count }
        return seen.sorted { rank($0) != rank($1) ? rank($0) < rank($1) : $0 < $1 }
            .map { TypeGroup(type: $0, albums: groups[$0] ?? []) }
    }

    /// downloaded once every track is on disk; otherwise wanted while
    /// monitored, and unmonitored when not.
    public static func albumState(monitored: Bool?, tracks: Int?, files: Int?) -> String {
        let total = tracks ?? 0
        if total > 0, (files ?? 0) >= total { return "downloaded" }
        return monitored == true ? "wanted" : "unmonitored"
    }

    /// An artist is downloaded once anything of theirs is on disk; a
    /// monitored artist with nothing yet is wanted.
    public static func artistState(monitored: Bool?, files: Int?) -> String {
        guard monitored == true else { return "unmonitored" }
        return (files ?? 0) > 0 ? "downloaded" : "wanted"
    }

    /// One disc or side of an album.
    public struct Disc: Equatable, Sendable {
        public var number: Int
        /// "Cassette", "CD · Bonus disc": the format and the medium's name, when Lidarr has them.
        public var label: String
        public var tracks: [AlbumTrack]
    }

    /// The tracks by medium, in medium order; the server sends them sorted
    /// within each.
    public static func discs(_ album: AlbumDetail) -> [Disc] {
        var media: [Int: [AlbumTrack]] = [:]
        for track in album.tracks ?? [] { media[track.medium ?? 1, default: []].append(track) }
        return media.keys.sorted().map { number in
            let medium = album.media?.first { $0.number == number }
            let label = [medium?.format, medium?.name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            return Disc(number: number, label: label, tracks: media[number] ?? [])
        }
    }

    /// Lidarr lists every link MusicBrainz has (an artist easily has forty);
    /// these are the ones worth a chip, in this order.
    static let sites: [(name: String, label: String)] = [
        ("discogs", "Discogs"), ("allmusic", "AllMusic"), ("last", "Last.fm"), ("wikidata", "Wikidata"),
        ("bandcamp", "Bandcamp"), ("spotify", "Spotify"), ("apple", "Apple Music"), ("tidal", "Tidal"),
        ("deezer", "Deezer"),
    ]
    static let maxLinks = 6

    public enum LinkKind: String, Sendable { case artist, releaseGroup = "release-group" }

    /// MusicBrainz first (the id Lidarr knows them by), then the best-known sites.
    public static func links(_ kind: LinkKind, slug: String?, links: [MusicLink]?) -> [ExternalLink] {
        var out: [ExternalLink] = []
        if let slug, let url = URL(string: "https://musicbrainz.org/\(kind.rawValue)/\(slug)") {
            out.append(.init(label: "MusicBrainz", url: url))
        }
        for site in sites where out.count < maxLinks {
            if let link = links?.first(where: { $0.name == site.name }), let url = URL(string: link.url) {
                out.append(.init(label: site.label, url: url))
            }
        }
        return out
    }

    /// "1 album", "5 albums".
    public static func albumCount(_ count: Int) -> String {
        count == 1 ? String(localized: "1 album") : String(localized: "\(count) albums")
    }

    /// "21 of 94 tracks on disk".
    public static func tracksOnDisk(have: Int, total: Int) -> String {
        String(localized: "\(have) of \(total) tracks on disk")
    }

    /// 4:05, or 1:02:09 past the hour; empty when unknown.
    public static func duration(_ seconds: Int?) -> String {
        guard let seconds, seconds > 0 else { return "" }
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60, rest = seconds % 60
        let ss = String(format: "%02d", rest)
        return hours > 0 ? "\(hours):\(String(format: "%02d", minutes)):\(ss)" : "\(minutes):\(ss)"
    }
}

extension LibraryAlbum {
    public var state: String { MusicLayout.albumState(monitored: monitored, tracks: track_count, files: track_file_count) }
}

extension AlbumDetail {
    public var state: String { MusicLayout.albumState(monitored: monitored, tracks: track_count, files: track_file_count) }
}

extension ArtistDetail {
    public var state: String { MusicLayout.artistState(monitored: monitored, files: track_file_count) }
}

// MARK: - Models

/// An artist as Lidarr keeps them: every album their metadata profile
/// allows, monitored or not (this is where an album gets monitored), grouped
/// by type, with the artist's own settings behind Edit.
@MainActor @Observable
public final class ArtistDetailModel {
    public let id: Int
    public private(set) var artist: Loadable<ArtistDetail> = .loading
    public private(set) var options: Options?
    public private(set) var tags: [LibraryTag] = []
    public private(set) var busy = false
    /// Set once the artist is gone from Lidarr; the view pops.
    public private(set) var deleted = false
    /// "Search started" and the like: what an action set off, briefly.
    public private(set) var notice: String?
    public var actionError: String?

    private let api: any LibraryAPI & MusicLibraryAPI & ManageAPI
    private let onSessionLost: @MainActor () -> Void
    private let settle: Duration

    /// `settle`: how long Lidarr gets to refresh before the page reads the artist again.
    public init(id: Int, api: any LibraryAPI & MusicLibraryAPI & ManageAPI, settle: Duration = .seconds(5),
                onSessionLost: @escaping @MainActor () -> Void) {
        self.id = id
        self.api = api
        self.settle = settle
        self.onSessionLost = onSessionLost
    }

    public var groups: [MusicLayout.TypeGroup] { MusicLayout.byType(artist.value?.albums ?? []) }

    public var links: [ExternalLink] {
        guard let artist = artist.value else { return [] }
        return MusicLayout.links(.artist, slug: artist.slug, links: artist.links)
    }

    public func load() async {
        await withDiscardingTaskGroup { group in
            group.addTask { await self.reload() }
            group.addTask { await self.loadOptions() }
        }
    }

    func reload() async {
        do {
            artist = .loaded(try await api.artistDetail(id))
        } catch APIError.unauthorized {
            onSessionLost()
        } catch {
            if artist.value == nil { artist = .failed(describe(error)) }
        }
    }

    /// The profiles and tags Edit offers.
    func loadOptions() async {
        options = try? await api.options(.lidarr)
        tags = (try? await api.tags(.lidarr)) ?? []
    }

    public func setMonitored(_ monitored: Bool) async {
        await perform { try await api.update(.artist(id), monitored: monitored, qualityProfile: nil) }
        await reload()
    }

    /// Every monitored album of theirs that is missing or below cutoff.
    public func search() async {
        if await perform({ try await api.triggerSearch(.artist(id)) }) { notice = String(localized: "Search started") }
    }

    public func refresh() async {
        guard await perform({ try await api.refreshArtist(id) }) else { return }
        notice = String(localized: "Lidarr is refreshing the artist")
        // the refresh runs in Lidarr; read the artist again once it has had a moment
        try? await Task.sleep(for: settle)
        await reload()
    }

    public func setAlbumMonitored(_ album: LibraryAlbum, _ monitored: Bool) async {
        await perform { try await api.update(.album(album.id), monitored: monitored, qualityProfile: nil) }
        await reload()
    }

    /// Returns whether it saved, so the sheet closes only then.
    @discardableResult
    public func save(_ changes: ArtistChanges) async -> Bool {
        guard !changes.isEmpty else { return true }
        let saved = await perform { try await api.updateArtist(id, changes) }
        await reload()
        return saved
    }

    public func delete(deleteFiles: Bool) async {
        if await perform({ try await api.delete(.artist(id), deleteFiles: deleteFiles) }) { deleted = true }
    }

    public func clearNotice() { notice = nil }

    @discardableResult
    private func perform(_ work: @Sendable () async throws -> Void) async -> Bool {
        busy = true
        defer { busy = false }
        do {
            try await work()
            return true
        } catch APIError.unauthorized {
            onSessionLost()
        } catch {
            actionError = describe(error)
        }
        return false
    }

    private func describe(_ error: any Error) -> String {
        (error as? APIError)?.description ?? error.localizedDescription
    }
}

/// One album: its tracks and which are on disk, in what quality, the
/// searches, and the files. Its quality profile is the artist's.
@MainActor @Observable
public final class AlbumDetailModel {
    public let id: Int
    public private(set) var album: Loadable<AlbumDetail> = .loading
    public private(set) var busy = false
    public private(set) var notice: String?
    public var actionError: String?

    private let api: any LibraryAPI & MusicLibraryAPI
    private let onSessionLost: @MainActor () -> Void

    public init(id: Int, api: any LibraryAPI & MusicLibraryAPI, onSessionLost: @escaping @MainActor () -> Void) {
        self.id = id
        self.api = api
        self.onSessionLost = onSessionLost
    }

    public var discs: [MusicLayout.Disc] { album.value.map(MusicLayout.discs) ?? [] }

    public var links: [ExternalLink] {
        guard let album = album.value else { return [] }
        return MusicLayout.links(.releaseGroup, slug: album.slug, links: album.links)
    }

    /// "Boards of Canada — Geogaddi", for the interactive search's heading.
    public var fullTitle: String {
        guard let album = album.value else { return "" }
        return [album.artist, album.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
    }

    public func load() async {
        do {
            album = .loaded(try await api.albumDetail(id))
        } catch APIError.unauthorized {
            onSessionLost()
        } catch {
            if album.value == nil { album = .failed(describe(error)) }
        }
    }

    public func setMonitored(_ monitored: Bool) async {
        await perform { try await api.update(.album(id), monitored: monitored, qualityProfile: nil) }
        await load()
    }

    public func search() async {
        if await perform({ try await api.triggerSearch(.album(id)) }) { notice = String(localized: "Search started") }
    }

    /// Every file of the album.
    public func deleteFiles() async {
        if await perform({ try await api.deleteAlbumFiles(album: id, file: nil) }) { notice = String(localized: "Files deleted") }
        await load()
    }

    public func deleteFile(of track: AlbumTrack) async {
        guard let file = track.file_id else { return }
        if await perform({ try await api.deleteAlbumFiles(album: id, file: file) }) { notice = String(localized: "Files deleted") }
        await load()
    }

    public func clearNotice() { notice = nil }

    @discardableResult
    private func perform(_ work: @Sendable () async throws -> Void) async -> Bool {
        busy = true
        defer { busy = false }
        do {
            try await work()
            return true
        } catch APIError.unauthorized {
            onSessionLost()
        } catch {
            actionError = describe(error)
        }
        return false
    }

    private func describe(_ error: any Error) -> String {
        (error as? APIError)?.description ?? error.localizedDescription
    }
}

// MARK: - Adding

/// Which of a new artist's albums Lidarr monitors: Lidarr's own choices.
public enum ArtistMonitor: String, CaseIterable, Sendable, Hashable {
    case all, future, missing, existing, latest, first, none

    public var label: String {
        switch self {
        case .all: String(localized: "All albums")
        case .future: String(localized: "Future albums")
        case .missing: String(localized: "Missing albums")
        case .existing: String(localized: "Existing albums")
        case .latest: String(localized: "Latest album")
        case .first: String(localized: "First album")
        case .none: String(localized: "None")
        }
    }
}

/// Adding an artist or an album from a music search. The MusicBrainz id is
/// the result's `foreign_id`; music's `remote_id` is always 0.
public protocol MusicAddAPI: Sendable {
    func addArtist(_ result: SearchResult, qualityProfile: Int, rootFolder: String,
                   metadataProfile: Int?, monitor: ArtistMonitor) async throws
    /// When Lidarr has no such artist yet they are added too, with these
    /// settings and only this album monitored.
    func addAlbum(_ result: SearchResult, qualityProfile: Int, rootFolder: String, metadataProfile: Int?) async throws
}
