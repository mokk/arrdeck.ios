import ArrdeckData
import Foundation

/// The library rows the detail pages, Wanted and the bookshelf share: a
/// Readarr book or author as the app shows it, a title's ratings and its
/// history events. Ported from the server's books.py, discover.py and
/// dashboard.py.
enum LibraryShapes {
    // MARK: - History

    /// A detail page's last dozen events, newest first as the arr sent them.
    static func history(_ records: [JSON]) -> [HistoryEvent] {
        records.prefix(12).map { HistoryEvent(date: $0["date"].string ?? "", _type: DashboardPort.label($0)) }
    }

    // MARK: - Ratings

    static let ratingSources = ["imdb", "tmdb", "rottenTomatoes", "metacritic", "trakt"]

    /// Every source the arr knows, for the detail pages. Sonarr sends one
    /// unlabelled value (IMDb's: the vote counts match), so it becomes "imdb".
    static func ratings(_ raw: JSON) -> [Rating] {
        let sources: JSON = raw.object["value"] != nil ? ["imdb": raw] : raw
        return ratingSources.compactMap { source in
            let entry = sources[source]
            guard let value = entry["value"].double, value != 0 else { return nil }
            return Rating(source: source, value: value, votes: entry["votes"].nonZero)
        }
    }

    // MARK: - Readarr

    static func hasFile(_ book: JSON) -> Bool {
        (book["statistics"]["bookFileCount"].int ?? 0) > 0
    }

    /// A book as the library lists it, with its author's name and profile:
    /// Readarr's book rows do not embed the author. The Books tab looks past
    /// a cover the device cannot load to one it can (`Artwork.musicCover`);
    /// the other book pages keep books.py's first-one-decides.
    static func bookRow(
        _ book: JSON, authors: [Int: JSON], cover: (JSON) -> String? = Artwork.bookCover
    ) -> LibraryBook {
        let author = book["authorId"].int.flatMap { authors[$0] } ?? .null
        return LibraryBook(
            added: book["added"].date,
            author: author["authorName"].string,
            author_id: book["authorId"].int,
            foreign_book_id: book["foreignBookId"].string,
            genres: book["genres"].array.compactMap(\.string),
            has_file: hasFile(book),
            id: book["id"].int ?? 0,
            monitored: book["monitored"].bool ?? false,
            page_count: book["pageCount"].nonZero,
            poster: cover(book["images"]),
            quality_profile_id: author["qualityProfileId"].int,
            rating: book["ratings"]["value"].double.flatMap { $0 == 0 ? nil : $0 },
            series_title: book["seriesTitle"].nonEmpty,
            size_on_disk: book["statistics"]["sizeOnDisk"].int ?? 0,
            slug: book["titleSlug"].string,
            title: book["title"].string,
            year: book["releaseDate"].year
        )
    }

    /// Adding an author makes Readarr list their whole bibliography,
    /// unmonitored. The library is what was asked for or is already there.
    static func inLibrary(monitored: Bool?, hasFile: Bool?) -> Bool {
        monitored == true || hasFile == true
    }

    static func authorRow(_ author: JSON) -> AuthorSummary {
        let stats = author["statistics"]
        return AuthorSummary(
            available_count: stats["availableBookCount"].int ?? 0,
            book_count: stats["bookCount"].int ?? 0,
            id: author["id"].int ?? 0,
            metadata_profile_id: author["metadataProfileId"].int,
            monitor_new_items: author["monitorNewItems"].string,
            monitored: author["monitored"].bool ?? false,
            name: author["authorName"].string,
            poster: Artwork.bookCover(author["images"]),
            quality_profile_id: author["qualityProfileId"].int,
            size_on_disk: stats["sizeOnDisk"].int ?? 0
        )
    }

    /// Readarr's series with their (bookId, position) links, joined with the
    /// books so each entry says what is there. Links to books not given are
    /// left out; the rest go in series order.
    static func seriesRows(_ series: [JSON], books: [Int: JSON]) -> [BookSeries] {
        series.map { entry in
            let linked = entry["links"].array.compactMap { link -> (order: Double, book: SeriesBook)? in
                guard let id = link["bookId"].int, let book = books[id] else { return nil }
                let row = SeriesBook(
                    book_id: id,
                    has_file: hasFile(book),
                    monitored: book["monitored"].bool ?? false,
                    position: link["position"].string,
                    poster: Artwork.bookCover(book["images"]),
                    title: book["title"].string,
                    year: book["releaseDate"].year
                )
                return (link["seriesPosition"].double ?? 0, row)
            }
            // stable, as Python's sort is: equal positions keep Readarr's order
            let ordered = linked.enumerated()
                .sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }
                .map(\.element.book)
            return BookSeries(books: ordered, id: entry["id"].int ?? 0, title: entry["title"].string)
        }
    }
}
