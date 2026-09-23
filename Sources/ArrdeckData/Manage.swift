import ArrdeckAPI
import Foundation
import Observation
import OpenAPIRuntime

public typealias LibraryMovie = Components.Schemas.LibraryMovieOut
public typealias LibrarySeries = Components.Schemas.LibrarySeriesOut
public typealias LibraryTag = Components.Schemas.TagOut
public typealias Indexer = Components.Schemas.IndexerOut
public typealias ServiceStatus = Components.Schemas.ServiceStatus
public typealias ScheduledTask = Components.Schemas.ScheduledTaskOut
public typealias ArrBackup = Components.Schemas.ArrBackupOut
public typealias LogEntry = Components.Schemas.LogEntryOut
public typealias ServiceSettings = Components.Schemas.ServiceSettingsOut
public typealias QualityProfiles = Components.Schemas.QualityProfilesOut
public typealias QualityProfileDetail = Components.Schemas.QualityProfileDetailOut

extension Components.Schemas.ServiceBlock_list_ScheduledTaskOut__: ServiceBlockShape {}
extension Components.Schemas.ServiceBlock_list_ArrBackupOut__: ServiceBlockShape {}

/// One row of either library, flattened so the list, its sort and its filter
/// are written once. The PWA's two lists were 76% identical and drifted.
public struct LibraryRow: Identifiable, Hashable, Sendable {
    public var id: Int
    public var ref: MediaRef
    public var title: String
    public var year: Int?
    public var poster: String?
    public var tags: [Int]
    public var monitored: Bool
    /// downloaded / wanted / unmonitored for movies; continuing / ended … for
    /// series, as Sonarr reports it.
    public var status: String
    public var sizeOnDisk: Int
    public var episodeFiles: Int?
    public var episodes: Int?
    public var tmdb: Int?
    public var tvdb: Int?
    public var imdb: String?

    public init(_ movie: LibraryMovie) {
        id = movie.id
        ref = .movie(movie.id)
        title = movie.title ?? ""
        year = movie.year
        poster = movie.poster
        tags = movie.tags ?? []
        monitored = movie.monitored ?? false
        // Radarr returns no single field for this, but the list sorts on it.
        status = movie.has_file == true ? "downloaded" : (movie.monitored == true ? "wanted" : "unmonitored")
        sizeOnDisk = movie.size_on_disk ?? 0
        tmdb = movie.tmdb_id
        imdb = movie.imdb_id
    }

    public init(_ series: LibrarySeries) {
        id = series.id
        ref = .series(series.id)
        title = series.title ?? ""
        year = series.year
        poster = series.poster
        tags = series.tags ?? []
        monitored = series.monitored ?? false
        status = series.status ?? ""
        sizeOnDisk = series.size_on_disk ?? 0
        episodeFiles = series.episode_file_count
        episodes = series.episode_count
        tmdb = nil
        tvdb = series.tvdb_id
        imdb = series.imdb_id
    }
}

public enum LibrarySort: String, CaseIterable, Sendable, Hashable {
    case title, year, status
    case size = "size_on_disk"
    case episodes = "episode_file_count"

    public var label: String {
        switch self {
        case .title: String(localized: "Title")
        case .year: String(localized: "Year")
        case .status: String(localized: "Status")
        case .size: String(localized: "Size")
        case .episodes: String(localized: "Episodes")
        }
    }

    public static func keys(for app: ArrApp) -> [LibrarySort] {
        app == .sonarr ? allCases : allCases.filter { $0 != .episodes }
    }
}

public enum LibrarySorting {
    /// Title filter is a case-insensitive substring; a tag filter keeps rows
    /// carrying that tag; the sort is stable and case-insensitive on text.
    public static func apply(
        _ rows: [LibraryRow], query: String, tag: Int?, sort: LibrarySort, descending: Bool
    ) -> [LibraryRow] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = rows.filter { row in
            (needle.isEmpty || row.title.lowercased().contains(needle))
                && (tag == nil || row.tags.contains(tag!))
        }
        return filtered.sorted { a, b in
            let less: Bool
            switch sort {
            case .title: less = a.title.lowercased() < b.title.lowercased()
            case .year: less = (a.year ?? 0) < (b.year ?? 0)
            case .status: less = a.status < b.status
            case .size: less = a.sizeOnDisk < b.sizeOnDisk
            case .episodes: less = (a.episodeFiles ?? 0) < (b.episodeFiles ?? 0)
            }
            return descending ? !less && !isEqual(a, b, sort) : less
        }
    }

    private static func isEqual(_ a: LibraryRow, _ b: LibraryRow, _ sort: LibrarySort) -> Bool {
        switch sort {
        case .title: a.title.lowercased() == b.title.lowercased()
        case .year: a.year == b.year
        case .status: a.status == b.status
        case .size: a.sizeOnDisk == b.sizeOnDisk
        case .episodes: a.episodeFiles == b.episodeFiles
        }
    }
}

extension ServiceStatus {
    /// Reachable but retrying is its own state: a green dot hides the problem
    /// and a red one implies it is down, so amber sits between the two.
    public var isFlaky: Bool { ok && (retries ?? 0) > 0 }
}

/// Which fields each service's connection form shows.
public enum ServiceField: String, CaseIterable, Sendable {
    case url, apiKey = "api_key", username, password

    public var label: String {
        switch self {
        case .url: String(localized: "URL")
        case .apiKey: String(localized: "API key")
        case .username: String(localized: "Username (optional)")
        case .password: String(localized: "Password (optional)")
        }
    }

    public static func fields(for service: String) -> [ServiceField] {
        switch service {
        case "qbittorrent": [.url, .username, .password]
        case "transmission", "prometheus": [.url]
        default: [.url, .apiKey]
        }
    }
}

/// The order the services list in — the arrs first, then the rest as the
/// backend defines them.
public let serviceOrder = ["radarr", "sonarr", "prowlarr", "qbittorrent", "transmission", "overseerr", "gluetun", "bazarr", "plex", "prometheus"]

public protocol ManageAPI: Sendable {
    func libraryMovies() async throws -> [LibraryMovie]
    func librarySeries() async throws -> [LibrarySeries]
    func tags(_ app: ArrApp) async throws -> [LibraryTag]
    func indexers() async throws -> [Indexer]
    func toggleIndexer(_ id: Int, enable: Bool) async throws
    func testIndexer(_ id: Int) async throws
    func status() async throws -> [ServiceStatus]
    func tasks() async throws -> Block<[ScheduledTask]>
    func arrBackups() async throws -> Block<[ArrBackup]>
    /// `app` is the service name — radarr, sonarr or prowlarr.
    func logs(_ app: String, level: String?) async throws -> [LogEntry]
    func qualityProfiles(_ app: ArrApp) async throws -> QualityProfiles
    func serviceSettings() async throws -> [String: ServiceSettings]
    /// Returns whether the service counts as configured after the save.
    func saveServiceSettings(_ name: String, url: String, apiKey: String, username: String, password: String) async throws -> Bool
    /// Returns the version the service reported.
    func testService(_ name: String) async throws -> String
}

extension LiveAPI: ManageAPI {
    public func libraryMovies() async throws -> [LibraryMovie] {
        try await call {
            switch try await client.library_movies_api_v1_library_movies_get() {
            case let .ok(ok): try ok.body.json
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func librarySeries() async throws -> [LibrarySeries] {
        try await call {
            switch try await client.library_series_api_v1_library_series_get() {
            case let .ok(ok): try ok.body.json
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func tags(_ app: ArrApp) async throws -> [LibraryTag] {
        try await call {
            switch try await client.tags_api_v1_tags__app__get(path: .init(app: app.rawValue)) {
            case let .ok(ok): try ok.body.json
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func indexers() async throws -> [Indexer] {
        try await call {
            switch try await client.indexers_api_v1_indexers_get() {
            case let .ok(ok): try ok.body.json
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func toggleIndexer(_ id: Int, enable: Bool) async throws {
        try await call {
            switch try await client.toggle_indexer_api_v1_indexers__indexer_id__patch(
                path: .init(indexer_id: id), query: .init(enable: enable)
            ) {
            case .ok: ()
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func testIndexer(_ id: Int) async throws {
        try await call {
            switch try await client.test_indexer_api_v1_indexers__indexer_id__test_post(path: .init(indexer_id: id)) {
            case .noContent: ()
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func status() async throws -> [ServiceStatus] {
        try await call {
            switch try await client.status_api_v1_status_get() {
            case let .ok(ok): try ok.body.json
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func tasks() async throws -> Block<[ScheduledTask]> {
        try await call {
            switch try await client.tasks_api_v1_tasks_get() {
            case let .ok(ok): Block(try ok.body.json)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func arrBackups() async throws -> Block<[ArrBackup]> {
        try await call {
            switch try await client.arr_backups_api_v1_arr_backups_get() {
            case let .ok(ok): Block(try ok.body.json)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func logs(_ app: String, level: String?) async throws -> [LogEntry] {
        try await call {
            switch try await client.logs_api_v1_logs__app__get(
                path: .init(app: app), query: .init(page: 1, level: level)
            ) {
            case let .ok(ok): try ok.body.json
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func qualityProfiles(_ app: ArrApp) async throws -> QualityProfiles {
        try await call {
            switch try await client.quality_profiles_api_v1_quality_profiles__app__get(path: .init(app: app.rawValue)) {
            case let .ok(ok): try ok.body.json
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func serviceSettings() async throws -> [String: ServiceSettings] {
        try await call {
            switch try await client.all_settings_api_v1_settings_services_get() {
            case let .ok(ok): try ok.body.json.additionalProperties
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func saveServiceSettings(_ name: String, url: String, apiKey: String, username: String, password: String) async throws -> Bool {
        try await call {
            switch try await client.save_settings_api_v1_settings_services__name__put(
                path: .init(name: name),
                body: .json(.init(api_key: apiKey, password: password, url: url, username: username))
            ) {
            case let .ok(ok):
                let payload = try ok.body.json.additionalProperties.value
                return payload["configured"] as? Bool ?? false
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func testService(_ name: String) async throws -> String {
        try await call {
            switch try await client.test_service_api_v1_settings_services__name__test_post(path: .init(name: name)) {
            case let .ok(ok):
                let payload = try ok.body.json.additionalProperties.value
                return payload["version"] as? String ?? ""
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }
}

// MARK: - Models

/// One arr's library: fetched once, filtered and sorted locally — a few
/// hundred rows, and the PWA did the same.
@MainActor @Observable
public final class LibraryListModel {
    public let app: ArrApp
    public var query = ""
    public var tag: Int?
    public var sort: LibrarySort = .title
    public var descending = false
    public private(set) var rows: Loadable<[LibraryRow]> = .loading
    public private(set) var tags: [LibraryTag] = []
    public private(set) var watchedMap: WatchedMap?

    private let api: any ManageAPI & LibraryAPI
    private let hasPlex: Bool
    private let onSessionLost: @MainActor () -> Void

    public init(app: ArrApp, api: any ManageAPI & LibraryAPI, hasPlex: Bool, onSessionLost: @escaping @MainActor () -> Void) {
        self.app = app
        self.api = api
        self.hasPlex = hasPlex
        self.onSessionLost = onSessionLost
    }

    public var shown: [LibraryRow] {
        LibrarySorting.apply(rows.value ?? [], query: query, tag: tag, sort: sort, descending: descending)
    }

    public func watched(_ row: LibraryRow) -> Watched? {
        Watched.lookup(watchedMap, tmdb: row.tmdb, tvdb: row.tvdb, imdb: row.imdb)
    }

    public func load() async {
        await withDiscardingTaskGroup { group in
            group.addTask { await self.loadRows() }
            group.addTask { await self.loadTags() }
            if hasPlex { group.addTask { await self.loadWatched() } }
        }
    }

    private func loadTags() async { tags = (try? await api.tags(app)) ?? [] }
    private func loadWatched() async { watchedMap = (try? await api.watched())?.value }

    private func loadRows() async {
        do {
            let rows: [LibraryRow] = switch app {
            case .radarr: try await api.libraryMovies().map(LibraryRow.init)
            case .sonarr: try await api.librarySeries().map(LibraryRow.init)
            }
            self.rows = .loaded(rows)
        } catch {
            if case .some(.unauthorized) = error as? APIError { onSessionLost(); return }
            if self.rows.value == nil { self.rows = .failed((error as? APIError)?.description ?? error.localizedDescription) }
        }
    }
}

@MainActor @Observable
public final class IndexersModel {
    public private(set) var indexers: Loadable<[Indexer]> = .loading
    /// Per indexer: the last test's verdict, until the next one.
    public private(set) var tested: [Int: Bool] = [:]
    public private(set) var pending: Set<Int> = []
    public var actionError: String?

    private let api: any ManageAPI
    private let onSessionLost: @MainActor () -> Void

    public init(api: any ManageAPI, onSessionLost: @escaping @MainActor () -> Void) {
        self.api = api
        self.onSessionLost = onSessionLost
    }

    public var sorted: [Indexer] {
        (indexers.value ?? []).sorted { ($0.name ?? "").lowercased() < ($1.name ?? "").lowercased() }
    }

    public func load() async {
        do {
            indexers = .loaded(try await api.indexers())
        } catch {
            if case .some(.unauthorized) = error as? APIError { onSessionLost(); return }
            if indexers.value == nil { indexers = .failed((error as? APIError)?.description ?? error.localizedDescription) }
        }
    }

    public func setEnabled(_ indexer: Indexer, _ enable: Bool) async {
        pending.insert(indexer.id)
        defer { pending.remove(indexer.id) }
        do {
            try await api.toggleIndexer(indexer.id, enable: enable)
            await load()
        } catch APIError.unauthorized {
            onSessionLost()
        } catch {
            actionError = (error as? APIError)?.description ?? error.localizedDescription
        }
    }

    /// A failed test is a result, not an error: the badge says so.
    public func test(_ indexer: Indexer) async {
        pending.insert(indexer.id)
        defer { pending.remove(indexer.id) }
        do {
            try await api.testIndexer(indexer.id)
            tested[indexer.id] = true
        } catch APIError.unauthorized {
            onSessionLost()
        } catch {
            tested[indexer.id] = false
        }
    }
}

@MainActor @Observable
public final class SystemModel {
    public let apps: [ArrApp]
    public private(set) var status: Loadable<[ServiceStatus]> = .loading
    public private(set) var tasks: Loadable<Block<[ScheduledTask]>> = .loading
    public private(set) var backups: Loadable<Block<[ArrBackup]>> = .loading
    public private(set) var profiles: [ArrApp: QualityProfiles] = [:]
    public var showAllTasks = false

    public var logApp: String {
        didSet { if logApp != oldValue { Task { await loadLogs() } } }
    }
    public var logLevel: String? {
        didSet { if logLevel != oldValue { Task { await loadLogs() } } }
    }
    public private(set) var logs: Loadable<[LogEntry]> = .loading

    private let api: any ManageAPI
    private let onSessionLost: @MainActor () -> Void
    private var logGeneration = 0

    /// `logApps` is every arr that has logs (Prowlarr included); `apps` are
    /// the two with quality profiles.
    public let logApps: [String]

    public init(configured: Set<String>, api: any ManageAPI, onSessionLost: @escaping @MainActor () -> Void) {
        apps = ArrApp.allCases.filter { configured.contains($0.rawValue) }
        logApps = ["radarr", "sonarr", "prowlarr"].filter { configured.contains($0) }
        logApp = logApps.first ?? "radarr"
        self.api = api
        self.onSessionLost = onSessionLost
    }

    /// Overdue tasks are the reason to look at the card, so they show even
    /// when they are not in the notable set.
    public var shownTasks: [ScheduledTask] {
        let all = tasks.value?.value ?? []
        return showAllTasks ? all : all.filter { $0.notable == true || $0.overdue == true }
    }

    public var overdueCount: Int { (tasks.value?.value ?? []).filter { $0.overdue == true }.count }

    public func load() async {
        await withDiscardingTaskGroup { group in
            group.addTask { await self.loadStatus() }
            group.addTask { await self.loadTasks() }
            group.addTask { await self.loadBackups() }
            group.addTask { await self.loadLogs() }
            for app in self.apps {
                group.addTask { await self.loadProfiles(app) }
            }
        }
    }

    private func loadProfiles(_ app: ArrApp) async { profiles[app] = try? await api.qualityProfiles(app) }
    private func loadStatus() async { await fetch(\.status) { try await api.status() } }
    private func loadTasks() async { await fetch(\.tasks) { try await api.tasks() } }
    private func loadBackups() async { await fetch(\.backups) { try await api.arrBackups() } }

    public func loadLogs() async {
        logGeneration += 1
        let mine = logGeneration
        let (name, level) = (logApp, logLevel)
        do {
            let entries = try await api.logs(name, level: level)
            guard mine == logGeneration else { return }
            logs = .loaded(entries)
        } catch {
            guard mine == logGeneration else { return }
            if case .some(.unauthorized) = error as? APIError { onSessionLost(); return }
            logs = .failed((error as? APIError)?.description ?? error.localizedDescription)
        }
    }

    private func fetch<V: Sendable & Equatable>(
        _ keyPath: ReferenceWritableKeyPath<SystemModel, Loadable<V>>, _ work: () async throws -> V
    ) async {
        do {
            self[keyPath: keyPath] = .loaded(try await work())
        } catch {
            if case .some(.unauthorized) = error as? APIError { onSessionLost(); return }
            if self[keyPath: keyPath].value == nil {
                self[keyPath: keyPath] = .failed((error as? APIError)?.description ?? error.localizedDescription)
            }
        }
    }
}

/// One service's connection form: the saved values, the edits, and the
/// outcome of the last save or test.
@MainActor @Observable
public final class ServiceForm: @MainActor Identifiable {
    public let name: String
    public let fields: [ServiceField]
    public private(set) var saved: ServiceSettings
    public var url: String
    public var apiKey: String
    public var username: String
    public var password: String
    public private(set) var result: String?
    public private(set) var resultOK = true
    public private(set) var busy = false

    public var id: String { name }

    init(name: String, saved: ServiceSettings) {
        self.name = name
        self.saved = saved
        fields = ServiceField.fields(for: name)
        url = saved.url ?? ""
        apiKey = saved.api_key ?? ""
        username = saved.username ?? ""
        password = saved.password ?? ""
    }

    public var configured: Bool { saved.configured ?? false }

    public var dirty: Bool {
        url != (saved.url ?? "") || apiKey != (saved.api_key ?? "")
            || username != (saved.username ?? "") || password != (saved.password ?? "")
    }

    func note(_ text: String, ok: Bool) {
        result = text
        resultOK = ok
    }

    func markSaved(configured: Bool) {
        saved = ServiceSettings(api_key: apiKey, configured: configured, password: password, url: url, username: username)
    }

    func setBusy(_ value: Bool) { busy = value }
}

@MainActor @Observable
public final class ServicesModel {
    public private(set) var forms: [ServiceForm] = []
    public private(set) var loaded = false
    public private(set) var error: String?
    public private(set) var status: [ServiceStatus] = []

    private let api: any ManageAPI
    private let onSessionLost: @MainActor () -> Void

    public init(api: any ManageAPI, onSessionLost: @escaping @MainActor () -> Void) {
        self.api = api
        self.onSessionLost = onSessionLost
    }

    public func load() async {
        do {
            let settings = try await api.serviceSettings()
            let ordered = serviceOrder.filter { settings[$0] != nil } + settings.keys.filter { !serviceOrder.contains($0) }.sorted()
            forms = ordered.map { ServiceForm(name: $0, saved: settings[$0]!) }
            loaded = true
            self.error = nil
            status = (try? await api.status()) ?? []
        } catch {
            if case .some(.unauthorized) = error as? APIError { onSessionLost(); return }
            if forms.isEmpty { self.error = (error as? APIError)?.description ?? error.localizedDescription }
        }
    }

    public func save(_ form: ServiceForm) async {
        form.setBusy(true)
        defer { form.setBusy(false) }
        do {
            let configured = try await api.saveServiceSettings(
                form.name, url: form.url, apiKey: form.apiKey, username: form.username, password: form.password
            )
            form.markSaved(configured: configured)
            form.note(String(localized: configured ? "ok: saved" : "saved (disabled)"), ok: true)
        } catch APIError.unauthorized {
            onSessionLost()
        } catch {
            form.note(String(localized: "error: \((error as? APIError)?.description ?? error.localizedDescription)"), ok: false)
        }
    }

    /// Tests the *saved* connection, so the button is disabled while dirty.
    public func test(_ form: ServiceForm) async {
        form.setBusy(true)
        defer { form.setBusy(false) }
        do {
            let version = try await api.testService(form.name)
            form.note(String(localized: "ok: v\(version)"), ok: true)
        } catch APIError.unauthorized {
            onSessionLost()
        } catch {
            form.note(String(localized: "error: \((error as? APIError)?.description ?? error.localizedDescription)"), ok: false)
        }
    }
}
