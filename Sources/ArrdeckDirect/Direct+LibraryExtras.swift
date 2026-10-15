import ArrdeckData
import Foundation

/// The per-title extras of LibraryAPI: Readarr's books, authors and editions
/// (books.py, discover.py), Bazarr's subtitles (subtitles.py) and Plex's
/// watched state (plex.py). Split from DirectBackend+Library.swift the way
/// TitleExtras.swift is from Library.swift.
extension DirectBackend {
    // MARK: - Readarr

    public func bookDetail(_ id: Int) async throws -> BookDetail {
        try await call {
            let readarr = try registry.arr("readarr")
            let book = try await readarr.get("/book/\(id)")
            let authorID = book["authorId"].nonZero
            // Everything past the book is decoration on its page: the author,
            // the history, the files and the series each go missing alone.
            async let author = Self.decoration(readarr, authorID.map { "/author/\($0)" })
            async let history = Self.decoration(readarr, "/history", query: [
                "pageSize": "50", "page": "1", "sortKey": "date", "sortDirection": "descending",
                "bookId": "\(id)", "includeBook": "true",
            ])
            async let files = Self.decoration(readarr, "/bookfile", query: ["bookId": "\(id)"])
            async let series = Self.seriesOf(readarr, author: authorID)
            async let downloadable = canDownload(readarr)
            return Self.bookDetail(
                book, author: await author, history: await history["records"].array,
                files: await files.array, series: await series, downloadable: await downloadable
            )
        }
    }

    /// A fetch for decoration: nothing when there is nothing to ask for, or
    /// the asking fails.
    private static func decoration(_ arr: KeyedClient, _ path: String?, query: [String: String?] = [:]) async -> JSON {
        guard let path else { return .null }
        return (try? await arr.get(path, query: query)) ?? .null
    }

    private static func seriesOf(_ readarr: KeyedClient, author: Int?) async -> [BookSeries] {
        guard let author else { return [] }
        return (try? await authorSeries(readarr, author: author)) ?? []
    }

    /// Whether the connected Readarr is our fork, which serves its files
    /// (`FileAddressAPI` hands out the address); an upstream build lists
    /// nothing. Asked on every book page, so cached as the server did.
    private func canDownload(_ readarr: KeyedClient) async -> Bool {
        let features = (try? await cached("readarr:fork_features", ttl: 300) {
            try await readarr.get("/system/status")["forkFeatures"].array.compactMap(\.string)
        }) ?? []
        return features.contains("bookFileDownload")
    }

    fileprivate static func bookDetail(
        _ book: JSON, author: JSON, history: [JSON], files: [JSON], series: [BookSeries], downloadable: Bool = false
    ) -> BookDetail {
        let id = book["id"].int ?? 0
        let ratings = book["ratings"]
        let goodreads = book["links"].array.first {
            ($0["name"].string ?? "").lowercased().contains("goodreads")
        }?["url"].string
        return BookDetail(
            author: author["authorName"].string,
            author_id: book["authorId"].int,
            downloadable: downloadable,
            editions: book["editions"].array.map { edition in
                BookEdition(
                    format: edition["format"].string,
                    is_ebook: edition["isEbook"].bool,
                    monitored: edition["monitored"].bool ?? false,
                    page_count: edition["pageCount"].nonZero,
                    title: edition["title"].string
                )
            },
            files: files.compactMap(Self.bookFile),
            genres: book["genres"].array.compactMap(\.string),
            goodreads_url: goodreads,
            has_file: LibraryShapes.hasFile(book),
            history: LibraryShapes.history(history),
            id: id,
            metadata_profile_id: author["metadataProfileId"].int,
            monitored: book["monitored"].bool ?? false,
            overview: book["overview"].string,
            page_count: book["pageCount"].nonZero,
            poster: LibraryShapes.bookCover(book["images"]),
            quality_profile_id: author["qualityProfileId"].int,
            rating: ratings["value"].double,
            rating_votes: ratings["votes"].int,
            release_date: book["releaseDate"].string,
            series: series.filter { $0.books?.contains { $0.book_id == id } == true },
            series_title: book["seriesTitle"].nonEmpty,
            size_on_disk: book["statistics"]["sizeOnDisk"].int ?? 0,
            title: book["title"].string,
            year: book["releaseDate"].year
        )
    }

    private static func bookFile(_ file: JSON) -> BookFile? {
        guard let id = file["id"].int else { return nil }
        let name = (file["path"].string ?? "").split(separator: "/").last.map(String.init)
        return BookFile(
            format: file["quality"]["quality"]["name"].string, id: id, name: name, size: file["size"].int ?? 0
        )
    }

    /// An author's series joined with their books, for a book page's "in
    /// this series".
    private static func authorSeries(_ readarr: KeyedClient, author: Int) async throws -> [BookSeries] {
        async let series = readarr.get("/series", query: ["authorId": "\(author)"])
        async let books = readarr.get("/book")
        let mine = try await books.array.filter { $0["authorId"].int == author }
        return LibraryShapes.seriesRows(try await series.array, books: mine.byID)
    }

    /// A book's own flag goes on the book; quality is the author's setting,
    /// so changing it here changes every book of theirs.
    func updateReadarrBook(_ id: Int, monitored: Bool?, qualityProfile: Int?) async throws {
        let readarr = try registry.arr("readarr")
        var book = try await readarr.get("/book/\(id)")
        if let monitored {
            book = book.setting("monitored", .bool(monitored))
            // GET /book/{id} leaves the editions out and a PUT without them
            // is a 500 (ArgumentNullException); Readarr's own UI has them
            if book["editions"].isNull {
                book = book.setting("editions", try await readarr.get("/edition", query: ["bookId": "\(id)"]))
            }
            let updated = try await readarr.send("PUT", "/book/\(id)", json: book)
            if !updated.isNull { book = updated }
        }
        if let qualityProfile, let authorID = book["authorId"].nonZero {
            let author = try await readarr.get("/author/\(authorID)")
            try await readarr.send("PUT", "/author/\(authorID)", json: author.setting("qualityProfileId", JSON(qualityProfile)))
            forget("readarr:authors")
        }
    }

    public func authorDetail(_ id: Int) async throws -> AuthorDetail {
        try await call {
            let readarr = try registry.arr("readarr")
            async let fetched = readarr.get("/author/\(id)")
            async let allBooks = readarr.get("/book")
            async let allSeries = readarr.get("/series", query: ["authorId": "\(id)"])
            let author = try await fetched
            let mine = try await allBooks.array.filter { $0["authorId"].int == id }
            let row = LibraryShapes.authorRow(author)
            let books = mine.map { LibraryShapes.bookRow($0, authors: [id: author]) }
                .enumerated()
                .sorted { ($0.element.year ?? 0, ($0.element.title ?? "").lowercased(), $0.offset)
                    < ($1.element.year ?? 0, ($1.element.title ?? "").lowercased(), $1.offset) }
                .map(\.element)
            return AuthorDetail(
                available_count: row.available_count,
                book_count: row.book_count,
                books: books,
                id: row.id,
                metadata_profile_id: row.metadata_profile_id,
                monitor_new_items: row.monitor_new_items,
                monitored: row.monitored,
                name: row.name,
                overview: author["overview"].string,
                poster: row.poster,
                quality_profile_id: row.quality_profile_id,
                series: LibraryShapes.seriesRows(try await allSeries.array, books: mine.byID),
                size_on_disk: row.size_on_disk
            )
        }
    }

    public func updateAuthor(_ id: Int, monitored: Bool?, monitorNewItems: String?) async throws -> AuthorSummary {
        try await call {
            let readarr = try registry.arr("readarr")
            var author = try await readarr.get("/author/\(id)")
            if let monitored { author = author.setting("monitored", .bool(monitored)) }
            if let monitorNewItems { author = author.setting("monitorNewItems", .string(monitorNewItems)) }
            let updated = try await readarr.send("PUT", "/author/\(id)", json: author)
            forget("readarr:authors", "library_map:book")
            return LibraryShapes.authorRow(updated)
        }
    }

    /// Every edition of the work one edition belongs to, for the add sheet's
    /// language and format picker. Only our Readarr fork's lookup carries
    /// editions; upstream's comes back empty and the sheet keeps the one it
    /// had.
    public func bookEditions(edition: String) async throws -> [EditionChoice] {
        try await call {
            let results = try await registry.arr("readarr").get("/book/lookup", query: ["term": "edition:\(edition)"])
            return results[0]["editions"].array.compactMap { edition in
                guard let id = edition["foreignEditionId"].string else { return nil }
                return EditionChoice(
                    foreign_edition_id: id,
                    format: edition["format"].string,
                    language: edition["language"].string,
                    monitored: edition["monitored"].bool ?? false,
                    page_count: edition["pageCount"].nonZero,
                    title: edition["title"].string,
                    year: edition["releaseDate"].year
                )
            }
        }
    }

    // MARK: - Bazarr

    public func movieSubtitles(_ id: Int) async throws -> TitleSubtitles {
        try await call {
            let rows = try await registry.bazarr().get(
                "/movies", query: ["start": "0", "length": "-1", "radarrid[]": "\(id)"]
            )["data"].array
            return Self.titleSubtitles(rows.first)
        }
    }

    public func seriesSubtitles(_ id: Int) async throws -> [EpisodeSubtitles] {
        try await call {
            let rows = try await registry.bazarr().get("/episodes", query: ["seriesid[]": "\(id)"])["data"].array
            return rows.compactMap { row in
                guard let episode = row["sonarrEpisodeId"].nonZero else { return nil }
                return EpisodeSubtitles(
                    episode: row["episode"].int ?? 0,
                    episode_id: episode,
                    season: row["season"].int ?? 0,
                    subtitles: Self.titleSubtitles(row)
                )
            }
        }
    }

    /// Bazarr's row for a movie or an episode as present and missing tracks.
    /// A title without a language profile has nothing to be missing, which is
    /// not the same as complete — hence `tracked`.
    fileprivate static func titleSubtitles(_ row: JSON?) -> TitleSubtitles {
        guard let row else { return TitleSubtitles(missing: [], present: [], tracked: false) }
        func track(_ sub: JSON) -> SubtitleTrack {
            SubtitleTrack(
                code: sub["code2"].string ?? "",
                forced: sub["forced"].bool ?? false,
                hi: sub["hi"].bool ?? false,
                language: sub["name"].nonEmpty ?? sub["code2"].string ?? "",
                path: sub["path"].string
            )
        }
        // Movies carry their language profile, and one without is untracked.
        // Episode rows do not carry it at all, so they count as tracked.
        let profile = row.object["profileId"]
        return TitleSubtitles(
            missing: row["missing_subtitles"].array.map(track),
            present: row["subtitles"].array.map(track),
            tracked: profile.map { !$0.isNull } ?? true
        )
    }

    /// Bazarr searches its providers for the language and keeps the best hit.
    public func downloadSubtitle(_ target: SubtitleTarget, language: String) async throws {
        try await call {
            let bazarr = try registry.bazarr()
            switch target {
            case let .movie(id):
                _ = try await bazarr.raw("PATCH", "/movies/subtitles", query: [
                    "radarrid": "\(id)", "language": language, "hi": "false", "forced": "false",
                ])
            case let .episode(series, episode):
                _ = try await bazarr.raw("PATCH", "/episodes/subtitles", query: [
                    "seriesid": "\(series)", "episodeid": "\(episode)", "language": language,
                    "hi": "false", "forced": "false",
                ])
            }
            forget("subtitles")
        }
    }

    // MARK: - Plex

    /// Watched state keyed by external id (tmdb:123, imdb:tt123, tvdb:123):
    /// one call per library section rather than per title, joined to the
    /// arrs' ids by the screens. Ten minutes, and the last good map while
    /// Plex is away.
    public func watched() async throws -> Block<WatchedMap> {
        await guarded("watched:block") {
            try await cached("watched", ttl: 600) {
                try await Self.loadWatched(registry.plex())
            }
        }
    }

    static func loadWatched(_ plex: KeyedClient) async throws -> WatchedMap {
        async let identity = try? plex.get("/identity")
        async let listed = plex.get("/library/sections")
        let sections = try await listed["MediaContainer"]["Directory"].array
            .filter { ["movie", "show"].contains($0["type"].string ?? "") }
        let machine = await identity?["MediaContainer"]["machineIdentifier"].string ?? ""
        let contents = await withTaskGroup(of: (Int, [JSON]?).self) { group in
            for (index, section) in sections.enumerated() {
                let key = section["key"].string ?? section["key"].int.map(String.init) ?? ""
                group.addTask {
                    // includeGuids gives the imdb/tmdb/tvdb ids inline, which is
                    // what lets this join the arrs without a lookup per title
                    let items = try? await plex.get("/library/sections/\(key)/all", query: ["includeGuids": "1"], timeout: 30)
                    return (index, items?["MediaContainer"]["Metadata"].array)
                }
            }
            var out = [[JSON]?](repeating: nil, count: sections.count)
            for await (index, items) in group { out[index] = items }
            return out
        }
        var items: [String: WatchedItem] = [:]
        for (section, entries) in zip(sections, contents) {
            // a section Plex could not list is left out, not the whole map
            for item in entries ?? [] {
                let entry = Self.watchEntry(section["type"].string ?? "", item)
                for key in Self.guidKeys(item) { items[key] = entry }
            }
        }
        return WatchedMap(
            base_url: machine.isEmpty
                ? nil : "https://app.plex.tv/desktop/#!/server/\(machine)/details?key=/library/metadata/",
            items: .init(additionalProperties: items)
        )
    }

    /// "imdb://tt123" as "imdb:tt123", for every id Plex knows the item by.
    static func guidKeys(_ item: JSON) -> [String] {
        item["Guid"].array.compactMap { guid in
            guard let raw = guid["id"].string, let range = raw.range(of: "://") else { return nil }
            return "\(raw[..<range.lowerBound]):\(raw[range.upperBound...])"
        }
    }

    /// A show counts as watched once every episode has been played; partly
    /// seen is neither watched nor never watched.
    fileprivate static func watchEntry(_ sectionType: String, _ item: JSON) -> WatchedItem {
        let watched: Bool, progress: Double
        if sectionType == "show" {
            let total = item["leafCount"].int ?? 0, seen = item["viewedLeafCount"].int ?? 0
            progress = total > 0 ? Double(seen) / Double(total) : 0
            watched = total > 0 && seen >= total
        } else {
            watched = (item["viewCount"].int ?? 0) != 0
            progress = watched ? 1 : 0
        }
        let key = item["ratingKey"].string ?? item["ratingKey"].int.map(String.init)
        return WatchedItem(
            key: key.flatMap { $0.isEmpty ? nil : $0 }, last_viewed_at: item["lastViewedAt"].int, progress: progress, watched: watched
        )
    }
}
