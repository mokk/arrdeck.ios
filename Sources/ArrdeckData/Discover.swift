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
    case movies, series

    public var app: ArrApp { self == .movies ? .radarr : .sonarr }
    public var label: String { self == .movies ? "Movies" : "Series" }
}

extension SearchResult {
    /// The library title, once it is one.
    public var ref: MediaRef? {
        guard let library_id else { return nil }
        return kind == .movie ? .movie(library_id) : .series(library_id)
    }

    public var app: ArrApp { kind == .movie ? .radarr : .sonarr }

    /// Not in library / monitored / downloaded / in library, unmonitored.
    public var libraryState: String {
        guard in_library == true else { return "not in library" }
        if has_file == true { return "downloaded" }
        return monitored == true ? "monitored" : "in library, unmonitored"
    }

    public var externalLinks: [ExternalLink] {
        var links: [ExternalLink] = []
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
    func add(_ result: SearchResult, qualityProfile: Int, rootFolder: String) async throws
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

    public func add(_ result: SearchResult, qualityProfile: Int, rootFolder: String) async throws {
        try await call {
            switch result.kind {
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
    case movies, series, collections, releases

    public var label: String {
        switch self {
        case .movies: "Movies"
        case .series: "Series"
        case .collections: "Collections"
        case .releases: "Releases"
        }
    }

    public var service: String {
        switch self {
        case .movies, .collections: "radarr"
        case .series: "sonarr"
        case .releases: "prowlarr"
        }
    }

    public var prompt: String {
        switch self {
        case .movies: "Search movies…"
        case .series: "Search series…"
        case .collections: "Filter by name…"
        case .releases: "Search raw releases…"
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
        guard tab == .movies || tab == .series else { return }
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
        case .movies, .series:
            let kind: MediaKind = tab == .movies ? .movies : .series
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
    }

    public func add() async {
        guard let qualityProfile, let rootFolder else { return }
        await perform { try await api.add(result, qualityProfile: qualityProfile, rootFolder: rootFolder) }
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
        case .all: "All"
        case .movie: "Movies"
        case .tv: "TV"
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
