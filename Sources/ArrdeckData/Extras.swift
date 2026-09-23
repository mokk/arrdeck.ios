import ArrdeckAPI
import Foundation
import Observation

public typealias ArrRelease = Components.Schemas.ArrReleaseOut
public typealias RenamePreview = Components.Schemas.RenamePreviewOut

/// What an interactive search is for. Radarr searches per movie; Sonarr's
/// release lookup needs a season or an episode, never the whole series.
public enum ReleaseTarget: Hashable, Sendable {
    case movie(Int)
    case season(series: Int, season: Int)
    case episode(series: Int, episode: Int)
    case book(Int)

    public var app: ArrApp {
        switch self {
        case .movie: .radarr
        case .season, .episode: .sonarr
        case .book: .readarr
        }
    }
}

public enum QueuePosition: String, CaseIterable, Sendable {
    case top, up, down, bottom

    public var label: String {
        switch self {
        case .top: String(localized: "Top")
        case .up: String(localized: "Up")
        case .down: String(localized: "Down")
        case .bottom: String(localized: "Bottom")
        }
    }
}

public enum TagChange: String, Sendable {
    case add, remove, replace
}

public protocol ExtrasAPI: Sendable {
    func releases(_ target: ReleaseTarget) async throws -> [ArrRelease]
    func grabArrRelease(_ app: ArrApp, guid: String, indexerID: Int) async throws
    func renamePreview(_ ref: MediaRef) async throws -> [RenamePreview]
    func renameFiles(_ ref: MediaRef, fileIDs: [Int]) async throws
    func addTorrent(_ client: TorrentClient, url: String, category: String, paused: Bool) async throws
    func qbitCategories() async throws -> [String]
    func qbitTags() async throws -> [String]
    func setLimits(_ client: TorrentClient, id: String, downloadKiB: Int, uploadKiB: Int) async throws
    func setPriority(_ client: TorrentClient, ids: [String], position: QueuePosition) async throws
    func forceStart(ids: [String]) async throws
    func setTags(ids: [String], tags: [String], remove: Bool) async throws
    func setCategory(id: String, category: String) async throws
    func bulkEdit(_ app: ArrApp, ids: [Int], monitored: Bool?, qualityProfile: Int?, tags: [Int]?, tagChange: TagChange?) async throws
    func bulkDelete(_ app: ArrApp, ids: [Int], deleteFiles: Bool) async throws
    func bulkSearch(_ app: ArrApp, ids: [Int]) async throws
}

extension ArrApp {
    /// The library kind the bulk endpoints are keyed by.
    var libraryKind: String {
        switch self {
        case .radarr: "movies"
        case .sonarr: "series"
        case .readarr: "books"
        }
    }
}

extension LiveAPI: ExtrasAPI {
    public func releases(_ target: ReleaseTarget) async throws -> [ArrRelease] {
        try await call {
            switch target {
            case let .movie(id):
                switch try await client.movie_releases_api_v1_releases_movie__movie_id__get(path: .init(movie_id: id)) {
                case let .ok(ok): return try ok.body.json
                case .unprocessableContent: throw APIError.unexpectedStatus(422)
                case let .undocumented(code, _): throw APIError.status(code)
                }
            case let .season(series, season):
                switch try await client.series_releases_api_v1_releases_series__series_id__get(
                    path: .init(series_id: series), query: .init(season: season)
                ) {
                case let .ok(ok): return try ok.body.json
                case .unprocessableContent: throw APIError.unexpectedStatus(422)
                case let .undocumented(code, _): throw APIError.status(code)
                }
            case let .episode(series, episode):
                switch try await client.series_releases_api_v1_releases_series__series_id__get(
                    path: .init(series_id: series), query: .init(episode_id: episode)
                ) {
                case let .ok(ok): return try ok.body.json
                case .unprocessableContent: throw APIError.unexpectedStatus(422)
                case let .undocumented(code, _): throw APIError.status(code)
                }
            case let .book(id):
                switch try await client.book_releases_api_v1_releases_book__book_id__get(path: .init(book_id: id)) {
                case let .ok(ok): return try ok.body.json
                case .unprocessableContent: throw APIError.unexpectedStatus(422)
                case let .undocumented(code, _): throw APIError.status(code)
                }
            }
        }
    }

    public func grabArrRelease(_ app: ArrApp, guid: String, indexerID: Int) async throws {
        try await call {
            switch try await client.grab_arr_release_api_v1_releases__app__grab_post(
                path: .init(app: app.rawValue), body: .json(.init(guid: guid, indexer_id: indexerID))
            ) {
            case .noContent: ()
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func renamePreview(_ ref: MediaRef) async throws -> [RenamePreview] {
        try await call {
            switch try await client.rename_preview_api_v1_rename__app___item_id__get(path: .init(app: ref.app.rawValue, item_id: ref.id)) {
            case let .ok(ok): try ok.body.json
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func renameFiles(_ ref: MediaRef, fileIDs: [Int]) async throws {
        try await call {
            switch try await client.rename_files_api_v1_rename__app__post(
                path: .init(app: ref.app.rawValue), body: .json(.init(file_ids: fileIDs, id: ref.id))
            ) {
            case .noContent: ()
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func addTorrent(_ torrentClient: TorrentClient, url: String, category: String, paused: Bool) async throws {
        try await call {
            switch try await client.add_torrent_api_v1_torrents__client__add_post(
                path: .init(client: torrentClient.rawValue), body: .json(.init(category: category, paused: paused, url: url))
            ) {
            case .noContent: ()
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func qbitCategories() async throws -> [String] {
        try await call {
            switch try await client.qbit_categories_api_v1_torrents_qbittorrent_categories_get() {
            case let .ok(ok): try ok.body.json
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func qbitTags() async throws -> [String] {
        try await call {
            switch try await client.qbit_tags_api_v1_torrents_qbittorrent_tags_get() {
            case let .ok(ok): try ok.body.json
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func setLimits(_ torrentClient: TorrentClient, id: String, downloadKiB: Int, uploadKiB: Int) async throws {
        try await call {
            switch try await client.torrent_limits_api_v1_torrents__client___torrent_id__limits_post(
                path: .init(client: torrentClient.rawValue, torrent_id: id), body: .json(.init(dl_kib: downloadKiB, ul_kib: uploadKiB))
            ) {
            case .noContent: ()
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func setPriority(_ torrentClient: TorrentClient, ids: [String], position: QueuePosition) async throws {
        try await call {
            let payload = Components.Schemas.TorrentPriorityIn.positionPayload(rawValue: position.rawValue) ?? .top
            switch try await client.torrent_priority_api_v1_torrents__client__priority_post(
                path: .init(client: torrentClient.rawValue), body: .json(.init(ids: ids, position: payload))
            ) {
            case .noContent: ()
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func forceStart(ids: [String]) async throws {
        try await call {
            switch try await client.torrent_force_start_api_v1_torrents_qbittorrent_force_start_post(body: .json(.init(ids: ids, value: true))) {
            case .noContent: ()
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func setTags(ids: [String], tags: [String], remove: Bool) async throws {
        try await call {
            switch try await client.qbit_set_tags_api_v1_torrents_qbittorrent_tags_post(body: .json(.init(ids: ids, remove: remove, tags: tags))) {
            case .noContent: ()
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func setCategory(id: String, category: String) async throws {
        try await call {
            switch try await client.torrent_category_api_v1_torrents_qbittorrent__torrent_id__category_post(
                path: .init(torrent_id: id), body: .json(.init(category: category))
            ) {
            case .noContent: ()
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func bulkEdit(_ app: ArrApp, ids: [Int], monitored: Bool?, qualityProfile: Int?, tags: [Int]?, tagChange: TagChange?) async throws {
        try await call {
            let apply = tagChange.flatMap { Components.Schemas.BulkEditIn.apply_tagsPayload(rawValue: $0.rawValue) }
            switch try await client.library_bulk_edit_api_v1_library__kind__bulk_post(
                path: .init(kind: app.libraryKind),
                body: .json(.init(apply_tags: apply, ids: ids, monitored: monitored, quality_profile_id: qualityProfile, tags: tags))
            ) {
            case .noContent: ()
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func bulkDelete(_ app: ArrApp, ids: [Int], deleteFiles: Bool) async throws {
        try await call {
            switch try await client.library_bulk_delete_api_v1_library__kind__bulk_delete_post(
                path: .init(kind: app.libraryKind), body: .json(.init(delete_files: deleteFiles, ids: ids))
            ) {
            case .noContent: ()
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func bulkSearch(_ app: ArrApp, ids: [Int]) async throws {
        try await call {
            switch try await client.library_bulk_search_api_v1_library__kind__bulk_search_post(
                path: .init(kind: app.libraryKind), body: .json(.init(delete_files: false, ids: ids))
            ) {
            case .noContent: ()
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }
}

// MARK: - Models

/// Interactive search: the arr's indexers queried for one title, season or
/// episode, each release grabbable. Rejected releases stay listed but dimmed
/// — the reason is the useful part.
@MainActor @Observable
public final class ReleasesModel {
    public let target: ReleaseTarget
    public private(set) var releases: Loadable<[ArrRelease]> = .loading
    public private(set) var grabbed: Set<String> = []
    public private(set) var pending: Set<String> = []
    public var actionError: String?

    private let api: any ExtrasAPI
    private let onSessionLost: @MainActor () -> Void

    public init(target: ReleaseTarget, api: any ExtrasAPI, onSessionLost: @escaping @MainActor () -> Void) {
        self.target = target
        self.api = api
        self.onSessionLost = onSessionLost
    }

    public func load() async {
        do {
            releases = .loaded(try await api.releases(target))
        } catch {
            if case .some(.unauthorized) = error as? APIError { onSessionLost(); return }
            releases = .failed((error as? APIError)?.description ?? error.localizedDescription)
        }
    }

    public func grab(_ release: ArrRelease) async {
        pending.insert(release.guid)
        defer { pending.remove(release.guid) }
        do {
            try await api.grabArrRelease(target.app, guid: release.guid, indexerID: release.indexer_id)
            grabbed.insert(release.guid)
        } catch APIError.unauthorized {
            onSessionLost()
        } catch {
            actionError = (error as? APIError)?.description ?? error.localizedDescription
        }
    }
}

/// Files whose names drifted from the arr's naming scheme. Empty means the
/// card is absent — its presence is the signal.
@MainActor @Observable
public final class RenameModel {
    public let ref: MediaRef
    public private(set) var previews: [RenamePreview] = []
    public private(set) var busy = false
    public private(set) var started = false
    public var actionError: String?

    private let api: any ExtrasAPI
    private let onSessionLost: @MainActor () -> Void

    public init(ref: MediaRef, api: any ExtrasAPI, onSessionLost: @escaping @MainActor () -> Void) {
        self.ref = ref
        self.api = api
        self.onSessionLost = onSessionLost
    }

    public func load() async {
        previews = (try? await api.renamePreview(ref)) ?? []
    }

    public func renameAll() async {
        busy = true
        defer { busy = false }
        do {
            try await api.renameFiles(ref, fileIDs: previews.map(\.file_id))
            started = true
            previews = []
        } catch APIError.unauthorized {
            onSessionLost()
        } catch {
            actionError = (error as? APIError)?.description ?? error.localizedDescription
        }
    }
}

/// Adding a torrent by magnet or URL. (.torrent files need a multipart
/// upload the generated client does not yet do; that arrives with the file
/// importer.)
@MainActor @Observable
public final class AddTorrentModel {
    public let clients: [TorrentClient]
    public var client: TorrentClient {
        didSet { if client != oldValue { Task { await loadCategories() } } }
    }
    public var url = ""
    public var category = ""
    public var paused = false
    public private(set) var categories: [String] = []
    public private(set) var busy = false
    public private(set) var done = false
    public var error: String?

    private let api: any ExtrasAPI
    private let onSessionLost: @MainActor () -> Void

    public init(clients: [TorrentClient], api: any ExtrasAPI, onSessionLost: @escaping @MainActor () -> Void) {
        self.clients = clients
        client = clients.first ?? .qbittorrent
        self.api = api
        self.onSessionLost = onSessionLost
    }

    public var canSubmit: Bool { !url.trimmingCharacters(in: .whitespaces).isEmpty && !busy }

    public func loadCategories() async {
        categories = client == .qbittorrent ? ((try? await api.qbitCategories()) ?? []) : []
    }

    public func add() async {
        busy = true
        defer { busy = false }
        do {
            try await api.addTorrent(client, url: url.trimmingCharacters(in: .whitespaces), category: category, paused: paused)
            done = true
        } catch APIError.unauthorized {
            onSessionLost()
        } catch {
            self.error = (error as? APIError)?.description ?? error.localizedDescription
        }
    }
}

/// Limits, queue position, category and tags for one torrent — the parts of
/// the detail sheet that write back.
@MainActor @Observable
public final class TorrentExtrasModel {
    public let torrent: Torrent
    public var downloadKiB = ""
    public var uploadKiB = ""
    public private(set) var savedDownload = 0
    public private(set) var savedUpload = 0
    public private(set) var category: String?
    public private(set) var categories: [String] = []
    public private(set) var allTags: [String] = []
    public private(set) var tags: Set<String>
    public private(set) var busy = false
    public var actionError: String?

    private let api: any ExtrasAPI
    private let onSessionLost: @MainActor () -> Void

    public init(torrent: Torrent, api: any ExtrasAPI, onSessionLost: @escaping @MainActor () -> Void) {
        self.torrent = torrent
        tags = Set(torrent.tags ?? [])
        self.api = api
        self.onSessionLost = onSessionLost
    }

    public var isQbit: Bool { torrent.torrentClient == .qbittorrent }

    public var limitsDirty: Bool {
        (Int(downloadKiB) ?? 0) != savedDownload || (Int(uploadKiB) ?? 0) != savedUpload
    }

    /// Seeds the editable fields from the details the sheet already fetched.
    public func apply(_ details: TorrentDetails) {
        savedDownload = details.dl_limit_kib ?? 0
        savedUpload = details.ul_limit_kib ?? 0
        downloadKiB = String(savedDownload)
        uploadKiB = String(savedUpload)
        category = details.category
        categories = details.categories ?? []
    }

    public func loadTags() async {
        guard isQbit else { return }
        allTags = (try? await api.qbitTags()) ?? []
    }

    public func saveLimits() async {
        let down = Int(downloadKiB) ?? 0, up = Int(uploadKiB) ?? 0
        await perform { try await api.setLimits(torrent.torrentClient, id: torrent.id, downloadKiB: down, uploadKiB: up) }
        if actionError == nil { savedDownload = down; savedUpload = up }
    }

    public func move(_ position: QueuePosition) async {
        await perform { try await api.setPriority(torrent.torrentClient, ids: [torrent.id], position: position) }
    }

    public func forceStart() async {
        await perform { try await api.forceStart(ids: [torrent.id]) }
    }

    public func setCategory(_ value: String) async {
        await perform { try await api.setCategory(id: torrent.id, category: value) }
        if actionError == nil { category = value.isEmpty ? nil : value }
    }

    public func toggle(tag: String) async {
        let had = tags.contains(tag)
        await perform { try await api.setTags(ids: [torrent.id], tags: [tag], remove: had) }
        if actionError == nil { if had { tags.remove(tag) } else { tags.insert(tag) } }
    }

    private func perform(_ work: @Sendable () async throws -> Void) async {
        busy = true
        defer { busy = false }
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
