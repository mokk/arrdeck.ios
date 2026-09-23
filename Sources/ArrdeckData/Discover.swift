import ArrdeckAPI
import Foundation
import Observation

public typealias SearchResult = Components.Schemas.SearchResultOut
public typealias Release = Components.Schemas.ReleaseOut
public typealias PopularSnapshot = Components.Schemas.PopularSnapshotOut
public typealias PopularIndexer = Components.Schemas.PopularIndexerOut
public typealias PopularRelease = Components.Schemas.PopularReleaseOut
public typealias Collection = Components.Schemas.CollectionOut
public typealias CollectionDetail = Components.Schemas.CollectionDetailOut
public typealias RootFolder = Components.Schemas.RootFolderOut

extension Components.Schemas.ServiceBlock_PopularSnapshotOut_: ServiceBlockShape {}

public enum MediaKind: String, CaseIterable, Sendable, Hashable {
    case movies, series, books

    public var app: ArrApp {
        switch self {
        case .movies: .radarr
        case .series: .sonarr
        case .books: .readarr
        }
    }

    public var label: String {
        switch self {
        case .movies: String(localized: "Movies")
        case .series: String(localized: "Series")
        case .books: String(localized: "Books")
        }
    }
}

extension SearchResult {
    /// The library title, once it is one.
    public var ref: MediaRef? {
        guard let library_id else { return nil }
        switch kind {
        case .movie: return .movie(library_id)
        case .series: return .series(library_id)
        case .book: return .book(library_id)
        }
    }

    public var app: ArrApp {
        switch kind {
        case .movie: .radarr
        case .series: .sonarr
        case .book: .readarr
        }
    }

    /// "Movie", "Series" or "Book", for the sheet's first badge.
    public var kindLabel: String {
        switch kind {
        case .movie: String(localized: "Movie")
        case .series: String(localized: "Series")
        case .book: String(localized: "Book")
        }
    }

    /// Not in library / monitored / downloaded / in library, unmonitored.
    public var libraryState: String {
        guard in_library == true else { return String(localized: "not in library") }
        if has_file == true { return String(localized: "downloaded") }
        return String(localized: monitored == true ? "monitored" : "in library, unmonitored")
    }

    public var externalLinks: [ExternalLink] {
        var links: [ExternalLink] = []
        if kind == .book { return links }
        if let imdb = imdb_id, let url = URL(string: "https://www.imdb.com/title/\(imdb)/") {
            links.append(.init(label: "IMDb", url: url))
        }
        if let tmdb = tmdb_id, let url = URL(string: "https://www.themoviedb.org/\(kind == .movie ? "movie" : "tv")/\(tmdb)") {
            links.append(.init(label: "TMDB", url: url))
        }
        if kind == .series, let url = URL(string: "https://www.thetvdb.com/dereferrer/series/\(remote_id)") {
            links.append(.init(label: "TVDB", url: url))
        }
        return links
    }
}

extension PopularRelease {
    /// Hours since the indexer published it; nil when it did not say.
    public func hoursOld(now: Date = .now) -> Double? {
        guard let published, let date = Format.parseDate(published) else { return nil }
        return now.timeIntervalSince(date) / 3600
    }
}

public protocol DiscoverAPI: Sendable {
    func search(_ kind: MediaKind, query: String) async throws -> [SearchResult]
    func searchReleases(_ query: String) async throws -> [Release]
    func discover(_ kind: MediaKind) async throws -> [SearchResult]
    func grab(guid: String, indexerID: Int) async throws
    /// `metadataProfile` matters for books only: Readarr keeps it on the author.
    func add(_ result: SearchResult, qualityProfile: Int, rootFolder: String, metadataProfile: Int?, edition: String?) async throws
    func collections() async throws -> [Collection]
    func collectionDetail(_ id: Int) async throws -> CollectionDetail
    func setCollectionMonitored(_ id: Int, _ monitored: Bool) async throws
    func popular(hours: Int, limit: Int) async throws -> Block<PopularSnapshot>
}

extension LiveAPI: DiscoverAPI {
    public func search(_ kind: MediaKind, query: String) async throws -> [SearchResult] {
        try await call {
            switch kind {
            case .movies:
                switch try await client.search_movies_api_v1_search_movies_get(query: .init(q: query)) {
                case let .ok(ok): return try ok.body.json
                case .unprocessableContent: throw APIError.unexpectedStatus(422)
                case let .undocumented(code, _): throw APIError.status(code)
                }
            case .series:
                switch try await client.search_series_api_v1_search_series_get(query: .init(q: query)) {
                case let .ok(ok): return try ok.body.json
                case .unprocessableContent: throw APIError.unexpectedStatus(422)
                case let .undocumented(code, _): throw APIError.status(code)
                }
            case .books:
                switch try await client.search_books_api_v1_search_books_get(query: .init(q: query)) {
                case let .ok(ok): return try ok.body.json
                case .unprocessableContent: throw APIError.unexpectedStatus(422)
                case let .undocumented(code, _): throw APIError.status(code)
                }
            }
        }
    }

    public func searchReleases(_ query: String) async throws -> [Release] {
        try await call {
            switch try await client.search_releases_api_v1_search_releases_get(query: .init(q: query)) {
            case let .ok(ok): try ok.body.json
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func discover(_ kind: MediaKind) async throws -> [SearchResult] {
        try await call {
            switch kind {
            case .movies:
                switch try await client.discover_movies_api_v1_discover_movies_get() {
                case let .ok(ok): return try ok.body.json
                case .unprocessableContent: throw APIError.unexpectedStatus(422)
                case let .undocumented(code, _): throw APIError.status(code)
                }
            case .series:
                switch try await client.discover_series_api_v1_discover_series_get() {
                case let .ok(ok): return try ok.body.json
                case .unprocessableContent: throw APIError.unexpectedStatus(422)
                case let .undocumented(code, _): throw APIError.status(code)
                }
            case .books:
                return [] // Overseerr has no popular list for books
            }
        }
    }

    public func grab(guid: String, indexerID: Int) async throws {
        try await call {
            switch try await client.grab_release_api_v1_releases_grab_post(body: .json(.init(guid: guid, indexer_id: indexerID))) {
            case .noContent: ()
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func add(_ result: SearchResult, qualityProfile: Int, rootFolder: String, metadataProfile: Int?, edition: String?) async throws {
        try await call {
            switch result.kind {
            case .book:
                switch try await client.add_book_api_v1_books_post(body: .json(.init(
                    foreign_book_id: result.foreign_id ?? String(result.remote_id),
                    foreign_edition_id: edition ?? result.foreign_edition_id,
                    metadata_profile_id: metadataProfile,
                    quality_profile_id: qualityProfile, root_folder_path: rootFolder,
                    title: result.title
                ))) {
                case .created: ()
                case .unprocessableContent: throw APIError.unexpectedStatus(422)
                case let .undocumented(code, _): throw APIError.status(code)
                }
            case .movie:
                switch try await client.add_movie_api_v1_movies_post(body: .json(.init(
                    quality_profile_id: qualityProfile, root_folder_path: rootFolder,
                    title: result.title, tmdb_id: result.remote_id
                ))) {
                case .created: ()
                case .unprocessableContent: throw APIError.unexpectedStatus(422)
                case let .undocumented(code, _): throw APIError.status(code)
                }
            case .series:
                switch try await client.add_series_api_v1_series_post(body: .json(.init(
                    quality_profile_id: qualityProfile, root_folder_path: rootFolder,
                    title: result.title, tvdb_id: result.remote_id
                ))) {
                case .created: ()
                case .unprocessableContent: throw APIError.unexpectedStatus(422)
                case let .undocumented(code, _): throw APIError.status(code)
                }
            }
        }
    }

    public func collections() async throws -> [Collection] {
        try await call {
            switch try await client.collections_api_v1_collections_get() {
            case let .ok(ok): try ok.body.json
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func collectionDetail(_ id: Int) async throws -> CollectionDetail {
        try await call {
            switch try await client.collection_detail_api_v1_collections__collection_id__get(path: .init(collection_id: id)) {
            case let .ok(ok): try ok.body.json
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func setCollectionMonitored(_ id: Int, _ monitored: Bool) async throws {
        try await call {
            switch try await client.toggle_collection_api_v1_collections__collection_id__patch(
                path: .init(collection_id: id), query: .init(monitored: monitored)
            ) {
            case .ok: ()
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func popular(hours: Int, limit: Int) async throws -> Block<PopularSnapshot> {
        try await call {
            switch try await client.popular_api_v1_popular_get(query: .init(hours: hours, limit: limit)) {
            case let .ok(ok): Block(try ok.body.json)
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }
}

// MARK: - Add

public enum AddTab: String, CaseIterable, Sendable, Hashable {
    case movies, series, books, collections, releases

    public var label: String {
        switch self {
        case .movies: String(localized: "Movies")
        case .series: String(localized: "Series")
        case .books: String(localized: "Books")
        case .collections: String(localized: "Collections")
        case .releases: String(localized: "Releases")
        }
    }

    public var service: String {
        switch self {
        case .movies, .collections: "radarr"
        case .series: "sonarr"
        case .books: "readarr"
        case .releases: "prowlarr"
        }
    }

    /// The library this tab searches; nil for collections and raw releases.
    public var mediaKind: MediaKind? { MediaKind(rawValue: rawValue) }

    public var prompt: String {
        switch self {
        case .movies: String(localized: "Search movies…")
        case .series: String(localized: "Search series…")
        case .books: String(localized: "Search books…")
        case .collections: String(localized: "Filter by name…")
        case .releases: String(localized: "Search raw releases…")
        }
    }
}

/// The Add tab: live search into Radarr/Sonarr (debounced), Overseerr's
/// popular titles while the box is empty, Radarr's collections, and raw
/// Prowlarr releases on submit only — the indexer fan-out is expensive.
@MainActor @Observable
public final class AddModel {
    public let tabs: [AddTab]
    public let canDiscover: Bool
    public var tab: AddTab {
        didSet { if tab != oldValue { tabChanged() } }
    }
    public var input = "" {
        didSet { if input != oldValue { inputChanged() } }
    }
    public private(set) var results: Loadable<[SearchResult]>?
    public private(set) var releases: Loadable<[Release]>?
    public private(set) var discover: [MediaKind: Loadable<[SearchResult]>] = [:]
    public private(set) var collections: Loadable<[Collection]> = .loading
    public private(set) var grabbed: Set<String> = []
    public private(set) var pending: Set<String> = []
    public var actionError: String?

    private let api: any DiscoverAPI
    private let onSessionLost: @MainActor () -> Void
    private var debounce: Task<Void, Never>?
    private var generation = 0

    public init(configured: Set<String>, api: any DiscoverAPI, onSessionLost: @escaping @MainActor () -> Void) {
        tabs = AddTab.allCases.filter { configured.contains($0.service) }
        canDiscover = configured.contains("overseerr")
        tab = tabs.first ?? .movies
        self.api = api
        self.onSessionLost = onSessionLost
    }

    /// Two or more characters, as the PWA requires before it asks.
    public var searching: Bool { input.trimmingCharacters(in: .whitespaces).count > 1 }

    public var shownCollections: [Collection] {
        let needle = input.lowercased()
        return (collections.value ?? []).filter { needle.isEmpty || ($0.title ?? "").lowercased().contains(needle) }
    }

    public func isPending(_ key: String) -> Bool { pending.contains(key) }

    public func load() async {
        switch tab {
        case .movies, .series:
            if canDiscover { await loadDiscover(tab == .movies ? .movies : .series) }
        case .books:
            break // Overseerr knows nothing about books: no popular list
        case .collections:
            await loadCollections()
        case .releases:
            break
        }
    }

    private func tabChanged() {
        input = ""
        results = nil
        releases = nil
        generation += 1
        Task { await load() }
    }

    private func inputChanged() {
        guard tab.mediaKind != nil else { return }
        debounce?.cancel()
        guard searching else { results = nil; generation += 1; return }
        debounce = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await submit()
        }
    }

    /// Runs the current query now — the return key, or the debounce firing.
    public func submit() async {
        guard searching else { return }
        generation += 1
        let mine = generation
        let query = input.trimmingCharacters(in: .whitespaces)
        switch tab {
        case .movies, .series, .books:
            let kind = tab.mediaKind ?? .movies
            if results?.value == nil { results = .loading }
            do {
                let found = try await api.search(kind, query: query)
                guard mine == generation else { return }
                results = .loaded(found)
            } catch {
                guard mine == generation else { return }
                if let reason = failure(error) { results = .failed(reason) }
            }
        case .releases:
            releases = .loading
            do {
                let found = try await api.searchReleases(query)
                guard mine == generation else { return }
                releases = .loaded(found)
            } catch {
                guard mine == generation else { return }
                if let reason = failure(error) { releases = .failed(reason) }
            }
        case .collections:
            break
        }
    }

    private func loadDiscover(_ kind: MediaKind) async {
        if discover[kind]?.value != nil { return }   // popular changes slowly; once per screen life
        discover[kind] = .loading
        do {
            discover[kind] = .loaded(try await api.discover(kind))
        } catch {
            if let reason = failure(error) { discover[kind] = .failed(reason) }
        }
    }

    private func loadCollections() async {
        do {
            collections = .loaded(try await api.collections())
        } catch {
            if let reason = failure(error), collections.value == nil { collections = .failed(reason) }
        }
    }

    public func grab(_ release: Release) async {
        await perform("grab-\(release.guid)") { try await api.grab(guid: release.guid, indexerID: release.indexer_id) }
        if actionError == nil { grabbed.insert(release.guid) }
    }

    public func setCollectionMonitored(_ collection: Collection, _ monitored: Bool) async {
        await perform("collection-\(collection.id)") { try await api.setCollectionMonitored(collection.id, monitored) }
        await loadCollections()
    }

    private func failure(_ error: any Error) -> String? {
        if case .some(.unauthorized) = error as? APIError { onSessionLost(); return nil }
        return (error as? APIError)?.description ?? error.localizedDescription
    }

    private func perform(_ key: String, _ work: @Sendable () async throws -> Void) async {
        pending.insert(key)
        defer { pending.remove(key) }
        actionError = nil
        do {
            try await work()
        } catch APIError.unauthorized {
            onSessionLost()
        } catch {
            actionError = (error as? APIError)?.description ?? error.localizedDescription
        }
    }
}

/// The add / edit sheet behind a search result: pick a profile and root
/// folder for a new title, or act on one already in the library.
@MainActor @Observable
public final class MediaSheetModel {
    public let result: SearchResult
    public private(set) var options: Options?
    public var qualityProfile: Int?
    public var rootFolder: String?
    /// Books only: the metadata profile a new author is created with.
    public var metadataProfile: Int?
    /// Books only: every edition of the work (from the Readarr fork's lookup;
    /// upstream gives just the one the search result had) and the pick.
    public private(set) var editions: [EditionChoice] = []
    public var edition: String?
    public private(set) var busy = false
    public private(set) var done = false
    public var error: String?

    private let api: any DiscoverAPI & LibraryAPI
    private let onSessionLost: @MainActor () -> Void

    public init(result: SearchResult, api: any DiscoverAPI & LibraryAPI, onSessionLost: @escaping @MainActor () -> Void) {
        self.result = result
        self.api = api
        self.onSessionLost = onSessionLost
    }

    public var canAdd: Bool { qualityProfile != nil && rootFolder != nil && !busy }

    public func load() async {
        options = try? await api.options(result.app)
        // The first of each is the default, as the PWA chose.
        if qualityProfile == nil { qualityProfile = result.quality_profile_id ?? options?.quality_profiles.first?.id }
        if rootFolder == nil { rootFolder = options?.root_folders.first?.path }
        if metadataProfile == nil { metadataProfile = options?.metadata_profiles?.first?.id }
        if result.kind == .book, result.in_library != true {
            editions = result.editions ?? []
            edition = edition ?? result.foreign_edition_id
            if let known = result.foreign_edition_id, let all = try? await api.bookEditions(edition: known), all.count > editions.count {
                editions = all
            }
        }
    }

    public func add() async {
        guard let qualityProfile, let rootFolder else { return }
        let metadataProfile = result.kind == .book ? metadataProfile : nil
        let edition = result.kind == .book ? edition : nil
        await perform { try await api.add(result, qualityProfile: qualityProfile, rootFolder: rootFolder, metadataProfile: metadataProfile, edition: edition) }
    }

    public func setMonitored(_ monitored: Bool) async {
        guard let ref = result.ref else { return }
        await perform { try await api.update(ref, monitored: monitored, qualityProfile: nil) }
    }

    public func setQualityProfile(_ id: Int) async {
        guard let ref = result.ref else { return }
        await perform { try await api.update(ref, monitored: nil, qualityProfile: id) }
    }

    public func search() async {
        guard let ref = result.ref else { return }
        await perform { try await api.triggerSearch(ref) }
    }

    public func delete(deleteFiles: Bool) async {
        guard let ref = result.ref else { return }
        await perform { try await api.delete(ref, deleteFiles: deleteFiles) }
    }

    /// Every action closes the sheet on success — the grid behind it refetches.
    private func perform(_ work: @Sendable () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await work()
            done = true
        } catch APIError.unauthorized {
            onSessionLost()
        } catch {
            self.error = (error as? APIError)?.description ?? error.localizedDescription
        }
    }
}

// MARK: - Popular

public enum PopularKind: String, CaseIterable, Sendable, Hashable {
    case all, movie, tv

    public var label: String {
        switch self {
        case .all: String(localized: "All")
        case .movie: String(localized: "Movies")
        case .tv: String(localized: "TV")
        }
    }
}

/// Torznab has no "trending", so this is the newest releases ranked by the
/// indexer's own grab count. 24h is what a single 100-result page can
/// honestly cover once the query is split per sub-category.
@MainActor @Observable
public final class PopularModel {
    public static let hours = 24
    public var kind: PopularKind = .all
    public private(set) var snapshot: Loadable<Block<PopularSnapshot>> = .loading
    public private(set) var grabbed: Set<String> = []
    public private(set) var pending: Set<String> = []
    public var actionError: String?

    private let api: any DiscoverAPI
    private let onSessionLost: @MainActor () -> Void

    public init(api: any DiscoverAPI, onSessionLost: @escaping @MainActor () -> Void) {
        self.api = api
        self.onSessionLost = onSessionLost
    }

    public func releases(of indexer: PopularIndexer) -> [PopularRelease] {
        (indexer.releases ?? []).filter { kind == .all || $0.kind == kind.rawValue }
    }

    public func load() async {
        do {
            snapshot = .loaded(try await api.popular(hours: PopularModel.hours, limit: 10))
        } catch {
            if case .some(.unauthorized) = error as? APIError { onSessionLost(); return }
            if snapshot.value == nil { snapshot = .failed((error as? APIError)?.description ?? error.localizedDescription) }
        }
    }

    public func grab(_ release: PopularRelease) async {
        guard let guid = release.guid, let indexer = release.indexer_id else { return }
        pending.insert(guid)
        defer { pending.remove(guid) }
        do {
            try await api.grab(guid: guid, indexerID: indexer)
            grabbed.insert(guid)
        } catch APIError.unauthorized {
            onSessionLost()
        } catch {
            actionError = (error as? APIError)?.description ?? error.localizedDescription
        }
    }
}
