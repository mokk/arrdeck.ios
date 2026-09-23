import Foundation
import Observation

/// Shared by both detail screens: the actions, the quality profiles, Plex's
/// watched state, and the one-shot lifecycle (no polling — the page is opened
/// deliberately and refetched after each action).
@MainActor @Observable
public class DetailModelBase {
    public let ref: MediaRef
    public private(set) var options: Options?
    public private(set) var watchedMap: WatchedMap?
    /// Set once the title is gone from the library; the view pops.
    public private(set) var deleted = false
    public var actionError: String?
    public private(set) var busy = false

    let api: any LibraryAPI
    let hasPlex: Bool
    let onSessionLost: @MainActor () -> Void
    var stopped = false

    init(ref: MediaRef, api: any LibraryAPI, hasPlex: Bool, onSessionLost: @escaping @MainActor () -> Void) {
        self.ref = ref
        self.api = api
        self.hasPlex = hasPlex
        self.onSessionLost = onSessionLost
    }

    public var qualityProfiles: [QualityProfile] { options?.quality_profiles ?? [] }

    func loadOptions() async {
        options = try? await api.options(ref.app)
    }

    /// Plex is asked once; a title's watched state does not change under a
    /// detail page.
    func loadWatched() async {
        guard hasPlex else { return }
        watchedMap = (try? await api.watched())?.value
    }

    public func setMonitored(_ monitored: Bool) async {
        await perform { try await api.update(ref, monitored: monitored, qualityProfile: nil) }
        await reload()
    }

    public func setQualityProfile(_ id: Int) async {
        await perform { try await api.update(ref, monitored: nil, qualityProfile: id) }
        await reload()
    }

    public func search() async {
        await perform { try await api.triggerSearch(ref) }
    }

    public func delete(deleteFiles: Bool) async {
        let ok = await perform { try await api.delete(ref, deleteFiles: deleteFiles) }
        if ok { deleted = true }
    }

    /// Overridden: refetch whatever the screen shows.
    func reload() async {}

    @discardableResult
    func perform(_ work: @Sendable () async throws -> Void) async -> Bool {
        busy = true
        defer { busy = false }
        do {
            try await work()
            return true
        } catch APIError.unauthorized {
            stopped = true
            onSessionLost()
        } catch {
            actionError = describe(error)
        }
        return false
    }

    func describe(_ error: any Error) -> String {
        (error as? APIError)?.description ?? error.localizedDescription
    }

    func failure(_ error: any Error) -> String? {
        if case .some(.unauthorized) = error as? APIError {
            stopped = true
            onSessionLost()
            return nil
        }
        return describe(error)
    }
}

@MainActor @Observable
public final class MovieDetailModel: DetailModelBase {
    public private(set) var movie: Loadable<MovieDetail> = .loading
    public private(set) var credits: Credits?

    public init(id: Int, api: any LibraryAPI, hasPlex: Bool, onSessionLost: @escaping @MainActor () -> Void) {
        super.init(ref: .movie(id), api: api, hasPlex: hasPlex, onSessionLost: onSessionLost)
    }

    public var watched: Watched? {
        guard let movie = movie.value else { return nil }
        return Watched.lookup(watchedMap, tmdb: movie.tmdb_id, imdb: movie.imdb_id)
    }

    public var links: [ExternalLink] {
        movie.value.map { ExternalLink.links(for: $0, watched: watched) } ?? []
    }

    public func load() async {
        await withDiscardingTaskGroup { group in
            group.addTask { await self.reload() }
            group.addTask { await self.loadOptions() }
            group.addTask { await self.loadWatched() }
            group.addTask { await self.loadCredits() }
        }
    }

    override func reload() async {
        do {
            movie = .loaded(try await api.movieDetail(ref.id))
        } catch {
            if let reason = failure(error), movie.value == nil { movie = .failed(reason) }
        }
    }

    /// Credits change almost never and are their own call; a title with none
    /// shows no section rather than an empty one.
    private func loadCredits() async {
        credits = try? await api.movieCredits(ref.id)
    }
}

@MainActor @Observable
public final class BookDetailModel: DetailModelBase {
    public private(set) var book: Loadable<BookDetail> = .loading

    public init(id: Int, api: any LibraryAPI, onSessionLost: @escaping @MainActor () -> Void) {
        super.init(ref: .book(id), api: api, hasPlex: false, onSessionLost: onSessionLost)
    }

    public var links: [ExternalLink] { book.value.map(ExternalLink.links(for:)) ?? [] }

    public func load() async {
        await withDiscardingTaskGroup { group in
            group.addTask { await self.reload() }
            group.addTask { await self.loadOptions() }
        }
    }

    override func reload() async {
        do {
            book = .loaded(try await api.bookDetail(ref.id))
        } catch {
            if let reason = failure(error), book.value == nil { book = .failed(reason) }
        }
    }
}

@MainActor @Observable
public final class SeriesDetailModel: DetailModelBase {
    public private(set) var series: Loadable<SeriesDetail> = .loading
    /// Episodes per season, fetched when a season is expanded.
    public private(set) var episodes: [Int: Loadable<[Episode]>] = [:]
    public var expanded: Set<Int> = []

    public init(id: Int, api: any LibraryAPI, hasPlex: Bool, onSessionLost: @escaping @MainActor () -> Void) {
        super.init(ref: .series(id), api: api, hasPlex: hasPlex, onSessionLost: onSessionLost)
    }

    public var watched: Watched? {
        guard let series = series.value else { return nil }
        return Watched.lookup(watchedMap, tmdb: series.tmdb_id, tvdb: series.tvdb_id, imdb: series.imdb_id)
    }

    public var links: [ExternalLink] {
        series.value.map { ExternalLink.links(for: $0, watched: watched) } ?? []
    }

    public func load() async {
        await withDiscardingTaskGroup { group in
            group.addTask { await self.reload() }
            group.addTask { await self.loadOptions() }
            group.addTask { await self.loadWatched() }
        }
    }

    override func reload() async {
        do {
            series = .loaded(try await api.seriesDetail(ref.id))
        } catch {
            if let reason = failure(error), series.value == nil { series = .failed(reason) }
        }
    }

    public func toggle(season: Int) async {
        if expanded.contains(season) {
            expanded.remove(season)
        } else {
            expanded.insert(season)
            if episodes[season] == nil { await loadEpisodes(season) }
        }
    }

    func loadEpisodes(_ season: Int) async {
        if episodes[season] == nil { episodes[season] = .loading }
        do {
            episodes[season] = .loaded(try await api.episodes(series: ref.id, season: season))
        } catch {
            if let reason = failure(error), episodes[season]?.value == nil { episodes[season] = .failed(reason) }
        }
    }

    public func setSeasonMonitored(_ season: Season, _ monitored: Bool) async {
        await perform { try await api.setSeasonMonitored(series: ref.id, season: season.number, monitored: monitored) }
        await reload()
        if expanded.contains(season.number) { await loadEpisodes(season.number) }
    }

    public func searchSeason(_ season: Season) async {
        await perform { try await api.searchSeason(series: ref.id, season: season.number) }
    }

    public func setEpisodeMonitored(_ episode: Episode, _ monitored: Bool) async {
        await perform { try await api.setEpisodesMonitored([episode.id], monitored: monitored) }
        await loadEpisodes(episode.season)
    }

    public func searchEpisode(_ episode: Episode) async {
        await perform { try await api.searchEpisodes([episode.id]) }
    }
}
