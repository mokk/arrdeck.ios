import ArrdeckAPI
import Foundation
import Testing
@testable import ArrdeckData

/// Answers captured from a dev arrdeck (the pinned server) talking to a test
/// Lidarr, trimmed: the artists, one artist's page and one album's.
enum MusicFixtures {
    static let artists = """
    [{"id": 1, "name": "Boards of Canada", "sort_name": "boards canada", "monitored": true, "album_count": 5,
      "track_file_count": 21, "poster": "/api/v1/library/artists/1/image/poster-250.jpg?v=639272944815209895",
      "track_count": 94, "size_on_disk": 18652867, "added": "2026-10-11T05:48:00Z", "quality_profile_id": 1,
      "metadata_profile_id": 1, "monitor_new_items": "all", "tags": [], "genres": ["Idm", "Electronic", "Ambient"],
      "rating": 9.6, "status": "continuing", "disambiguation": "Scottish electronic duo",
      "slug": "69158f97-4c07-4c4e-baf8-4e4ab1ed666e"},
     {"id": 6, "name": "Aphex Twin", "sort_name": "aphex twin", "monitored": true, "album_count": 6,
      "track_file_count": 0, "poster": "/api/v1/library/artists/6/image/poster-250.jpg?v=639272975327937901",
      "track_count": 124, "size_on_disk": 0, "added": "2026-10-11T06:38:52Z", "quality_profile_id": 1,
      "metadata_profile_id": 1, "monitor_new_items": "none", "tags": [], "genres": ["Electronic", "Idm", "Ambient"],
      "rating": 9.5, "status": "continuing", "disambiguation": null, "slug": "f22942a1-6f70-4f48-866e-238cb2308fbd"},
     {"id": 7, "name": "Autechre", "monitored": false, "album_count": 19, "track_file_count": 0, "track_count": 238,
      "size_on_disk": 0, "added": "2026-10-11T06:34:35Z", "tags": [3]}]
    """

    static let artist = """
    {"id": 1, "name": "Boards of Canada", "sort_name": "boards canada", "monitored": true, "album_count": 5,
     "track_file_count": 21, "poster": "/api/v1/library/artists/1/image/poster-500.jpg?v=639272944815209895",
     "track_count": 94, "size_on_disk": 18652867, "added": "2026-10-11T05:48:00Z", "quality_profile_id": 1,
     "metadata_profile_id": 1, "monitor_new_items": "all", "tags": [], "genres": ["Idm", "Electronic", "Ambient"],
     "rating": 9.6, "status": "continuing", "disambiguation": "Scottish electronic duo",
     "slug": "69158f97-4c07-4c4e-baf8-4e4ab1ed666e", "overview": null, "artist_type": "Group",
     "path": "/music/Boards of Canada", "root_folder_path": "/music",
     "fanart": "/api/v1/library/artists/1/image/fanart.jpg?v=639272944817131323",
     "links": [{"name": "boardsofcanada", "url": "http://www.boardsofcanada.com/"},
               {"name": "warp", "url": "https://warp.net/artists/boards-of-canada"},
               {"name": "discogs", "url": "https://www.discogs.com/artist/307"},
               {"name": "last", "url": "https://www.last.fm/music/Boards+of+Canada"},
               {"name": "wikidata", "url": "https://www.wikidata.org/wiki/Q722778"},
               {"name": "allmusic", "url": "https://www.allmusic.com/artist/mn0000758999"},
               {"name": "spotify", "url": "https://open.spotify.com/artist/2VAvhf61GgLYmC6C8anyX1"},
               {"name": "bandcamp", "url": "https://boardsofcanada.bandcamp.com/"}],
     "ratings": [{"source": "musicbrainz", "value": 9.6, "votes": 16}],
     "albums": [
       {"id": 9, "title": "Trans Canada Highway", "artist_id": 1, "year": 2006, "album_type": "EP",
        "monitored": false, "track_count": 6, "track_file_count": 0, "secondary_types": []},
       {"id": 1, "title": "Geogaddi", "artist_id": 1, "artist": "Boards of Canada", "year": 2002,
        "release_date": "2002-02-13T00:00:00Z", "album_type": "Album", "monitored": true, "track_count": 24,
        "track_file_count": 3, "size_on_disk": 1664416, "secondary_types": [], "rating": 9.2},
       {"id": 11, "title": "Peel Session", "artist_id": 1, "year": 1999, "album_type": "Broadcast",
        "monitored": false, "track_count": 3, "track_file_count": 0, "secondary_types": ["Live"]},
       {"id": 3, "title": "Music Has the Right to Children", "artist_id": 1, "artist": "Boards of Canada",
        "year": 1998, "release_date": "1998-04-20T00:00:00Z", "album_type": "Album", "monitored": true,
        "track_count": 18, "track_file_count": 18, "size_on_disk": 16988451, "secondary_types": [], "rating": 9.4},
       {"id": 12, "title": "Boc Maxima", "artist_id": 1, "year": 1996, "album_type": "Demo",
        "monitored": false, "track_count": 21, "track_file_count": 0, "secondary_types": []}]}
    """

    static let album = """
    {"id": 1, "title": "Geogaddi", "disambiguation": null, "artist": "Boards of Canada", "artist_id": 1,
     "overview": null, "poster": "/api/v1/poster?u=https%3A%2F%2Fimages.lidarr.audio%2Fx.jpg",
     "release_date": "2002-02-13T00:00:00Z", "year": 2002, "album_type": "Album", "secondary_types": [],
     "genres": ["Idm", "Electronic"], "monitored": true, "track_count": 24, "track_file_count": 3,
     "size_on_disk": 1664416, "duration": 4092, "quality_profile_id": 1,
     "ratings": [{"source": "musicbrainz", "value": 9.2, "votes": 25}],
     "links": [{"name": "discogs", "url": "https://www.discogs.com/master/2129"},
               {"name": "bbc", "url": "https://www.bbc.co.uk/music/reviews/jjbd"}],
     "slug": "8183834a-6c8a-39ef-a7bc-a82f79b929e9", "artist_slug": "69158f97-4c07-4c4e-baf8-4e4ab1ed666e",
     "release": "Cassette · Beat Records, Warp", "media": [{"number": 1, "name": null, "format": "Cassette"}],
     "tracks": [
       {"id": 69, "medium": 1, "number": "A1", "absolute": 1, "title": "Ready Lets Go", "duration": 59,
        "has_file": true, "file_id": 22, "quality": "MP3-32", "size": 234832},
       {"id": 70, "medium": 1, "number": "A2", "absolute": 2, "title": "Music Is Math", "duration": 321,
        "has_file": true, "file_id": 2, "quality": "MP3-32", "size": 1279824},
       {"id": 72, "medium": 1, "number": "A4", "absolute": 4, "title": "Gyroscope", "duration": 215,
        "has_file": false, "file_id": null, "quality": null, "size": null}],
     "history": [{"type": "deleted", "date": "2026-10-11T06:35:15Z"}, {"type": "imported", "date": "2026-10-11T06:06:31Z"}]}
    """
}

@Suite struct MusicLayoutTests {
    @Test func tracksSplitByDiscWithTheirMediumsLabel() {
        let album = AlbumDetail(
            id: 1,
            media: [.init(format: "CD", number: 1), .init(format: "CD", name: "Bonus", number: 2)],
            tracks: [.init(id: 3, medium: 2, title: "c"), .init(id: 1, medium: 1, title: "a"), .init(id: 2, title: "b")]
        )
        let discs = MusicLayout.discs(album)
        #expect(discs.map(\.number) == [1, 2])
        #expect(discs.map(\.label) == ["CD", "CD · Bonus"])
        #expect(discs[0].tracks.map(\.id) == [1, 2], "a track without a medium is on the first")
    }

    @Test func anAlbumIsDownloadedOnlyWhenEveryTrackIs() {
        #expect(MusicLayout.albumState(monitored: true, tracks: 10, files: 10) == "downloaded")
        #expect(MusicLayout.albumState(monitored: false, tracks: 10, files: 10) == "downloaded")
        #expect(MusicLayout.albumState(monitored: true, tracks: 10, files: 9) == "wanted")
        #expect(MusicLayout.albumState(monitored: false, tracks: 0, files: 0) == "unmonitored")
        #expect(MusicLayout.artistState(monitored: true, files: 0) == "wanted")
        #expect(MusicLayout.artistState(monitored: false, files: 5) == "unmonitored")
    }

    @Test func durationsReadLikeAPlayersClock() {
        #expect(MusicLayout.duration(245) == "4:05")
        #expect(MusicLayout.duration(3729) == "1:02:09")
        #expect(MusicLayout.duration(nil) == "" && MusicLayout.duration(0) == "")
    }

    @Test func theSortsAreAddedNameStatusTracksAndSize() {
        #expect(LibrarySort.keys(for: .lidarr) == [.added, .title, .status, .tracks, .size])
        #expect(LibrarySort.tracks.rawValue == "track_file_count", "the PWA's key")
        let rows = [
            LibraryRow(LibraryArtist(id: 1, name: "b", size_on_disk: 5, track_file_count: 2)),
            LibraryRow(LibraryArtist(id: 2, name: "A", size_on_disk: 9, track_file_count: 0)),
            LibraryRow(LibraryArtist(id: 3, name: "c", size_on_disk: 1, track_file_count: 7)),
        ]
        #expect(LibrarySorting.apply(rows, query: "", tag: nil, sort: .tracks, descending: true).map(\.id) == [3, 1, 2])
        #expect(LibrarySorting.apply(rows, query: "", tag: nil, sort: .title, descending: false).map(\.id) == [2, 1, 3])
        #expect(LibrarySorting.apply(rows, query: "", tag: nil, sort: .size, descending: true).map(\.id) == [2, 1, 3])
        #expect(LibraryLayout.options(for: .lidarr) == [.posters, .list, .details])
    }

    @Test func theDiskFilterKeepsWhatItSays() {
        let have = LibraryRow(LibraryArtist(id: 1, track_file_count: 2))
        let none = LibraryRow(LibraryArtist(id: 2, track_file_count: 0))
        #expect([have, none].filter(MusicDiskFilter.any.keeps).count == 2)
        #expect([have, none].filter(MusicDiskFilter.onDisk.keeps).map(\.id) == [1])
        #expect([have, none].filter(MusicDiskFilter.missing.keeps).map(\.id) == [2])
        #expect(MusicDiskFilter(rawValue: "onDisk") == .onDisk && MusicDiskFilter(rawValue: "") == .any, "the PWA's stored values")
    }

    @Test func editSendsOnlyWhatChanged() {
        let artist = ArtistDetail(id: 1, metadata_profile_id: 1, monitor_new_items: "all", path: "/music/BoC",
                                  quality_profile_id: 1, tags: [2, 5])
        let untouched = ArtistChanges.edit(artist, qualityProfile: 1, metadataProfile: 1, newAlbums: .all,
                                           path: " /music/BoC ", moveFiles: true, tags: [5, 2])
        #expect(untouched.isEmpty, "the same folder and the same tags in another order are no change")
        let changed = ArtistChanges.edit(artist, qualityProfile: 3, metadataProfile: 1, newAlbums: .none,
                                         path: "/music/Boards of Canada", moveFiles: true, tags: [2])
        #expect(changed == ArtistChanges(monitorNewItems: NewAlbums.none, qualityProfile: 3, path: "/music/Boards of Canada",
                                         moveFiles: true, tags: [2]))
        let blank = ArtistChanges.edit(artist, qualityProfile: 1, metadataProfile: 1, newAlbums: .all,
                                       path: "", moveFiles: true, tags: [2, 5])
        #expect(blank.path == nil && !blank.moveFiles, "a blank folder is not a move")
    }

    @Test func artistsAreFoundEverywhereAndInSpotlight() {
        let rows = [LibraryRow(LibraryArtist(disambiguation: "Scottish electronic duo", id: 1, name: "Boards of Canada")),
                    LibraryRow(LibraryMovie(id: 2, title: "Canada"))]
        let hits = GlobalSearch.hits(rows, authors: [], query: "canada")
        #expect(hits.map(\.group) == [.movies, .artists], "artists last")
        #expect(hits.last?.subtitle == "Scottish electronic duo")
        #expect(hits.last?.ref == .artist(1))
    }
}

// MARK: - the screens' models

actor FakeMusicAPI: LibraryAPI, MusicLibraryAPI, ManageAPI {
    var calls: [String] = []
    var artist = ArtistDetail(albums: [.init(album_type: "Album", id: 1, monitored: true, title: "Geogaddi")],
                              id: 1, monitored: true, name: "Boards of Canada")
    var failure: APIError?

    func set(failure: APIError?) { self.failure = failure }
    private func log(_ call: String) throws {
        calls.append(call)
        if let failure { throw failure }
    }

    // music
    func libraryArtists() async throws -> [LibraryArtist] { try log("artists"); return [] }
    func artistAlbums(_ artistID: Int) async throws -> [LibraryAlbum] { [] }
    func artistDetail(_ id: Int) async throws -> ArtistDetail { try log("artist-\(id)"); return artist }
    func updateArtist(_ id: Int, _ changes: ArtistChanges) async throws { try log("edit-\(id)-\(changes.qualityProfile ?? 0)") }
    func refreshArtist(_ id: Int) async throws { try log("refresh-\(id)") }
    func albumDetail(_ id: Int) async throws -> AlbumDetail {
        try log("album-\(id)")
        return AlbumDetail(artist: "Boards of Canada", id: id, monitored: true, title: "Geogaddi",
                           tracks: [.init(file_id: 22, has_file: true, id: 69, title: "Ready Lets Go"), .init(id: 72, title: "Gyroscope")])
    }
    func deleteAlbumFiles(album: Int, file: Int?) async throws { try log("delete-files-\(album)-\(file.map(String.init) ?? "all")") }

    // library
    func update(_ ref: MediaRef, monitored: Bool?, qualityProfile: Int?) async throws { try log("update-\(ref)-\(monitored.map(String.init) ?? "nil")") }
    func delete(_ ref: MediaRef, deleteFiles: Bool) async throws { try log("delete-\(ref)-\(deleteFiles)") }
    func triggerSearch(_ ref: MediaRef) async throws { try log("search-\(ref)") }
    func options(_ app: ArrApp) async throws -> Options {
        try log("options-\(app.rawValue)")
        return Options(metadata_profiles: [.init(id: 1, name: "Standard")], quality_profiles: [.init(id: 1, name: "Any")], root_folders: [])
    }
    func movieDetail(_ id: Int) async throws -> MovieDetail { throw APIError.unexpectedStatus(404) }
    func movieCredits(_ id: Int) async throws -> Credits { throw APIError.unexpectedStatus(404) }
    func seriesDetail(_ id: Int) async throws -> SeriesDetail { throw APIError.unexpectedStatus(404) }
    func bookDetail(_ id: Int) async throws -> BookDetail { throw APIError.unexpectedStatus(404) }
    func episodes(series: Int, season: Int) async throws -> [Episode] { [] }
    func watched() async throws -> Block<WatchedMap> { throw APIError.unexpectedStatus(404) }
    func setSeasonMonitored(series: Int, season: Int, monitored: Bool) async throws {}
    func searchSeason(series: Int, season: Int) async throws {}
    func movieSubtitles(_ id: Int) async throws -> TitleSubtitles { throw APIError.unexpectedStatus(404) }
    func seriesSubtitles(_ id: Int) async throws -> [EpisodeSubtitles] { [] }
    func downloadSubtitle(_ target: SubtitleTarget, language: String) async throws {}
    func deleteEpisodeFile(_ fileID: Int) async throws {}
    func authorDetail(_ id: Int) async throws -> AuthorDetail { throw APIError.unexpectedStatus(404) }
    func updateAuthor(_ id: Int, monitored: Bool?, monitorNewItems: String?) async throws -> AuthorSummary { throw APIError.unexpectedStatus(404) }
    func bookEditions(edition: String) async throws -> [EditionChoice] { [] }
    func setEpisodesMonitored(_ ids: [Int], monitored: Bool) async throws {}
    func searchEpisodes(_ ids: [Int]) async throws {}

    // manage: only tags matter here
    func tags(_ app: ArrApp) async throws -> [LibraryTag] { try log("tags-\(app.rawValue)"); return [.init(id: 3, label: "lossless")] }
    func libraryMovies() async throws -> [LibraryMovie] { [] }
    func librarySeries() async throws -> [LibrarySeries] { [] }
    func libraryBooks() async throws -> [LibraryBook] { [] }
    func indexers() async throws -> [Indexer] { [] }
    func toggleIndexer(_ id: Int, enable: Bool) async throws {}
    func testIndexer(_ id: Int) async throws {}
    func status() async throws -> [ServiceStatus] { [] }
    func tasks() async throws -> Block<[ScheduledTask]> { .healthy([]) }
    func arrBackups() async throws -> Block<[ArrBackup]> { .healthy([]) }
    func logs(_ app: String, level: String?) async throws -> [LogEntry] { [] }
    func qualityProfiles(_ app: ArrApp) async throws -> QualityProfiles { throw APIError.unexpectedStatus(404) }
    func serviceSettings() async throws -> [String: ServiceSettings] { [:] }
    func saveServiceSettings(_ name: String, url: String, apiKey: String, username: String, password: String) async throws -> Bool { true }
    func testService(_ name: String) async throws -> String { "" }
}

@MainActor @Suite struct MusicModelTests {
    @Test func theArtistPageLoadsWithLidarrsProfilesAndTags() async {
        let api = FakeMusicAPI()
        let model = ArtistDetailModel(id: 1, api: api, settle: .zero, onSessionLost: {})
        await model.load()
        #expect(model.artist.value?.name == "Boards of Canada")
        #expect(model.groups.map(\.type) == ["Album"])
        #expect(model.options?.metadata_profiles?.map(\.name) == ["Standard"])
        #expect(model.tags.map(\.label) == ["lossless"])
        #expect(Set(await api.calls) == ["artist-1", "options-lidarr", "tags-lidarr"])
    }

    @Test func theArtistsActionsReachTheArtistAndItsAlbums() async {
        let api = FakeMusicAPI()
        let model = ArtistDetailModel(id: 1, api: api, settle: .zero, onSessionLost: {})
        await model.setMonitored(false)
        await model.search()
        #expect(model.notice == "Search started")
        await model.refresh()
        await model.setAlbumMonitored(LibraryAlbum(id: 9), true)
        #expect(await model.save(ArtistChanges()), "nothing changed is nothing sent")
        #expect(await model.save(ArtistChanges(qualityProfile: 2)))
        await model.delete(deleteFiles: true)
        #expect(model.deleted)
        #expect(await api.calls == [
            "update-artist(1)-false", "artist-1", "search-artist(1)", "refresh-1", "artist-1",
            "update-album(9)-true", "artist-1", "edit-1-2", "artist-1", "delete-artist(1)-true",
        ])
    }

    @Test func aFailedActionSaysSoAndKeepsThePage() async {
        let api = FakeMusicAPI()
        let model = ArtistDetailModel(id: 1, api: api, settle: .zero, onSessionLost: {})
        await model.load()
        await api.set(failure: .unexpectedStatus(500))
        #expect(await model.save(ArtistChanges(qualityProfile: 2)) == false, "the sheet stays open")
        #expect(model.actionError != nil)
        #expect(model.artist.value != nil)
        await model.delete(deleteFiles: false)
        #expect(!model.deleted)
    }

    @Test func unauthorizedEndsTheSession() async {
        let api = FakeMusicAPI()
        await api.set(failure: .unauthorized)
        var lost = 0
        let model = AlbumDetailModel(id: 1, api: api, onSessionLost: { lost += 1 })
        await model.load()
        #expect(lost == 1)
        #expect(model.album == .loading)
    }

    @Test func theAlbumsActionsReachTheAlbumAndItsFiles() async {
        let api = FakeMusicAPI()
        let model = AlbumDetailModel(id: 4, api: api, onSessionLost: {})
        await model.load()
        #expect(model.fullTitle == "Boards of Canada — Geogaddi")
        #expect(model.discs.first?.tracks.count == 2)
        await model.setMonitored(false)
        await model.search()
        let track = model.album.value!.tracks![0]
        await model.deleteFile(of: track)
        await model.deleteFile(of: model.album.value!.tracks![1])   // no file: nothing sent
        await model.deleteFiles()
        #expect(await api.calls == [
            "album-4", "update-album(4)-false", "album-4", "search-album(4)",
            "delete-files-4-22", "album-4", "delete-files-4-all", "album-4",
        ])
    }
}

// MARK: - adding

@MainActor @Suite struct AddMusicTests {
    @Test func musicIsATabOnceLidarrIsConfiguredAndSearchesLidarr() async throws {
        let api = FakeDiscoverAPI()
        let model = AddModel(configured: ["radarr", "lidarr", "prowlarr"], api: api, onSessionLost: {})
        #expect(model.tabs == [.movies, .music, .collections, .releases])
        model.tab = .music
        await model.load()
        #expect(await api.count("discover-music") == 0, "nothing popular to show for music")
        model.input = "boards"
        await model.submit()
        #expect(await api.count("search-music-boards") >= 1)
        #expect(AddTab.music.mediaKind == .music && MediaKind.music.app == .lidarr)
    }

    @Test func anArtistIsAddedWithTheMonitorChoiceAndNoneDoesNotSearch() async {
        let api = FakeDiscoverAPI()
        let artist = SearchResult(foreign_id: "69158f97", kind: "artist", remote_id: 0, title: "Boards of Canada")
        let sheet = MediaSheetModel(result: artist, api: api, onSessionLost: {})
        await sheet.load()
        #expect(sheet.usesMetadataProfile)
        #expect(sheet.addSearches)
        sheet.artistMonitor = .none
        #expect(!sheet.addSearches)
        await sheet.add()
        #expect(await api.count("add-artist-69158f97-none") == 1)
        #expect(sheet.done)
    }

    @Test func anAlbumIsAddedThroughTheAddRoute() async {
        let api = FakeDiscoverAPI()
        let album = SearchResult(album_type: "EP", artist: "Cale Parks", foreign_id: "bd8ea9e2", kind: "album", remote_id: 0, title: "Boards")
        #expect(album.kindLabel == "EP", "Lidarr's own word for it")
        #expect(album.app == .lidarr && album.externalLinks.isEmpty)
        let sheet = MediaSheetModel(result: album, api: api, onSessionLost: {})
        await sheet.load()
        await sheet.add()
        #expect(await api.count("add-0-4-/movies") == 1)
    }

    @Test func musicInTheLibraryOpensItsPage() {
        #expect(SearchResult(in_library: true, kind: "artist", library_id: 1, remote_id: 0, title: "x").ref == .artist(1))
        #expect(SearchResult(in_library: true, kind: "album", library_id: 4, remote_id: 0, title: "x").ref == .album(4))
        #expect(SearchResult(kind: "album", remote_id: 0, title: "x").ref == nil)
    }
}
