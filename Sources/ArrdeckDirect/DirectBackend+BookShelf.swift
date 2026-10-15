import ArrdeckData
import Foundation

/// The bookshelf: every Readarr series with a book in the library, holding
/// all its books so the missing ones show as gaps. Ported from books.py.
extension DirectBackend: BookShelfAPI {
    /// Series lists change when an author is refreshed, which is rare; the
    /// shelf asks for every library author at once, so each answer is kept
    /// for an hour, and only a few are asked at a time.
    private static let shelfSeriesTTL: TimeInterval = 3600
    private static let shelfConcurrency = 4

    public func bookShelf() async throws -> [ShelfSeries] {
        try await call {
            let readarr = try registry.arr("readarr")
            async let fetched = readarr.get("/book")
            async let authorMap = readarrAuthors(readarr)
            let books = try await fetched.array
            let authors = try await authorMap
            let rows = books.map { LibraryShapes.bookRow($0, authors: authors) }
            let authorIDs = Set(rows.compactMap { row in
                LibraryShapes.inLibrary(monitored: row.monitored, hasFile: row.has_file) ? row.author_id : nil
            }).sorted()
            let series = await seriesByAuthor(readarr, authorIDs)
            return Self.shelfRows(authorIDs.map { ($0, series[$0] ?? []) }, books: books, authors: authors)
        }
    }

    /// Authors by id, kept a minute: the book rows need a name each and do
    /// not embed the author.
    private func readarrAuthors(_ readarr: KeyedClient) async throws -> [Int: JSON] {
        try await cached("readarr:authors", ttl: 60) {
            Dictionary(try await readarr.get("/author").array.compactMap { author in author["id"].int.map { ($0, author) } },
                       uniquingKeysWith: { _, last in last })
        }
    }

    /// Each author's series, at most `shelfConcurrency` asked at once. One
    /// author's failure leaves their series off rather than sinking the shelf.
    private func seriesByAuthor(_ readarr: KeyedClient, _ authorIDs: [Int]) async -> [Int: [JSON]] {
        await withTaskGroup(of: (Int, [JSON]).self) { group in
            func ask(_ author: Int) {
                group.addTask {
                    let series = try? await self.cached("readarr:series:\(author)", ttl: Self.shelfSeriesTTL) {
                        try await readarr.get("/series", query: ["authorId": "\(author)"])
                    }
                    return (author, series?.array ?? [])
                }
            }
            var pending = authorIDs[...]
            for _ in 0 ..< Self.shelfConcurrency {
                guard let next = pending.popFirst() else { break }
                ask(next)
            }
            var out: [Int: [JSON]] = [:]
            for await (author, series) in group {
                out[author] = series
                if let next = pending.popFirst() { ask(next) }
            }
            return out
        }
    }

    /// Series with at least one book in the library, by author and then
    /// series title. `books` is every book, so a series' gaps are named too.
    fileprivate static func shelfRows(
        _ seriesByAuthor: [(author: Int, series: [JSON])], books: [JSON], authors: [Int: JSON]
    ) -> [ShelfSeries] {
        let byID = books.byID
        var out: [ShelfSeries] = []
        for (author, series) in seriesByAuthor {
            let name = authors[author]?["authorName"].string
            for row in LibraryShapes.seriesRows(series, books: byID)
            where (row.books ?? []).contains(where: { LibraryShapes.inLibrary(monitored: $0.monitored, hasFile: $0.has_file) }) {
                out.append(ShelfSeries(author: name, author_id: author, books: row.books, id: row.id, title: row.title))
            }
        }
        func key(_ row: (offset: Int, element: ShelfSeries)) -> (String, String, Int) {
            ((row.element.author ?? "").lowercased(), (row.element.title ?? "").lowercased(), row.offset)
        }
        return out.enumerated().sorted { key($0) < key($1) }.map(\.element)
    }
}
