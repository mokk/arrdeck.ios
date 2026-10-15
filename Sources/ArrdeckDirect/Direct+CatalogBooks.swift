import ArrdeckData
import Foundation

/// Finding and adding books in Readarr, ported from the server's
/// discover.py. Readarr hangs books off authors: a new author comes in with
/// the book, monitoring just that one.
extension DirectBackend {
    /// Readarr's combined search, books only; an author entry is no result.
    func catalogBookSearch(_ query: String) async throws -> [SearchResult] {
        let readarr = try registry.arr("readarr")
        async let library = heldBooks(readarr)
        let entries = try await readarr.combinedSearch(query)
        let held = try await library
        return Array(entries.compactMap { BookCatalog.result($0, held: held) }.prefix(30))
    }

    /// The book is looked up again, by edition when there is one: the search
    /// result carried only ids, and Readarr wants the whole resource back,
    /// author and editions included.
    func catalogAddBook(
        _ result: SearchResult, edition: String?, qualityProfile: Int, rootFolder: String, metadataProfile: Int?
    ) async throws {
        let readarr = try registry.arr("readarr")
        let foreignID = result.foreign_id ?? String(result.remote_id)
        let edition = edition.flatMap { $0.isEmpty ? nil : $0 }
        let entries = try await readarr.combinedSearch(edition.map { "edition:\($0)" } ?? result.title)
        guard let book = entries.map({ $0["book"] })
            .first(where: { !$0.object.isEmpty && $0["foreignBookId"].string == foreignID })
        else { throw APIError.refused("Readarr no longer finds that book") }
        var metadata = metadataProfile
        if metadata == nil, (book["author"]["id"].int ?? 0) == 0 {
            metadata = try await readarr.get("/metadataprofile").array.first?["id"].int
        }
        let payload = BookCatalog.payload(
            book, edition: edition, qualityProfile: qualityProfile, rootFolder: rootFolder, metadataProfile: metadata
        )
        // a new author means Readarr pulls their whole bibliography before it answers
        try await readarr.send("POST", "/book", json: payload, timeout: 90)
        catalogForget("library_map:book", "readarr:authors")
    }

    /// Readarr's books by their numeric foreign id, for the in-library badge.
    private func heldBooks(_ readarr: KeyedClient) async throws -> [Int: Catalog.Held] {
        try await cached("library_map:book", ttl: 60) {
            var out: [Int: Catalog.Held] = [:]
            for book in try await readarr.get("/book").array {
                guard let foreign = Catalog.numeric(book["foreignBookId"]), let id = book["id"].int else { continue }
                out[foreign] = Catalog.Held(
                    libraryID: id, monitored: book["monitored"].bool ?? false, qualityProfile: nil,
                    hasFile: (book["statistics"]["bookFileCount"].int ?? 0) > 0
                )
            }
            return out
        }
    }
}

private extension KeyedClient {
    /// Author and book entries, each book with its author and editions — what
    /// adding needs. A fresh term sends Readarr to its metadata server for
    /// every hit's editions, which can take over a minute.
    func combinedSearch(_ term: String) async throws -> [JSON] {
        try await get("/search", query: ["term": term], timeout: 90).array
    }
}

private enum BookCatalog {
    /// One combined-search entry as a search result. The monitored edition
    /// is the one Readarr would add.
    static func result(_ entry: JSON, held: [Int: Catalog.Held]) -> SearchResult? {
        let book = entry["book"]
        guard !book.object.isEmpty else { return nil }
        let editions = book["editions"].array
        let edition = editions.first { $0["monitored"].bool == true } ?? editions.first ?? .null
        let foreign = Catalog.numeric(book["foreignBookId"])
        let result = SearchResult(
            author: book["author"]["authorName"].string,
            editions: editions.compactMap(choice),
            foreign_edition_id: edition["foreignEditionId"].nonEmpty ?? book["foreignEditionId"].string,
            foreign_id: book["foreignBookId"].string, kind: "book",
            overview: book["overview"].nonEmpty ?? edition["overview"].string, poster: cover(book),
            remote_id: foreign ?? 0, title: book["title"].string ?? "", year: book["releaseDate"].year
        )
        return Catalog.result(result, held: held[foreign ?? -1])
    }

    static func choice(_ edition: JSON) -> EditionChoice? {
        guard let id = edition["foreignEditionId"].nonEmpty else { return nil }
        return EditionChoice(
            foreign_edition_id: id, format: edition["format"].string, language: edition["language"].string,
            monitored: edition["monitored"].bool ?? false,
            page_count: edition["pageCount"].nonZero, title: edition["title"].string,
            year: edition["releaseDate"].year
        )
    }

    /// Readarr's own cover address first, else a cover or poster image.
    static func cover(_ book: JSON) -> String? {
        book["remoteCover"].nonEmpty.map { Artwork.normalise($0) } ?? Artwork.musicCover(book["images"])
    }

    /// A combined-search book shaped into what POST /book wants, the way
    /// Readarr's own Add dialog does: a new author gets the profiles, the
    /// folder and "monitor just this book"; an author Readarr has is left
    /// alone. The picked edition is the one monitored, and names the book.
    static func payload(
        _ book: JSON, edition: String?, qualityProfile: Int, rootFolder: String, metadataProfile: Int?
    ) -> JSON {
        var author = book["author"].object
        if (author["id"]?.int ?? 0) == 0 {
            author["monitored"] = true
            author["monitorNewItems"] = "none"
            author["qualityProfileId"] = JSON(qualityProfile)
            author["metadataProfileId"] = JSON(metadataProfile)
            author["rootFolderPath"] = .string(rootFolder)
            author["tags"] = []
            author["addOptions"] = ["searchForMissingBooks": false, "booksToMonitor": [book["foreignBookId"]]]
        }
        var payload = book
            .setting("author", .object(author))
            .setting("monitored", true)
            .setting("addOptions", ["searchForNewBook": true])
        let editions = book["editions"].array
        if let edition, editions.contains(where: { $0["foreignEditionId"].string == edition }) {
            payload = payload
                .setting("editions", .array(editions.map {
                    $0.setting("monitored", .bool($0["foreignEditionId"].string == edition))
                }))
                .setting("foreignEditionId", .string(edition))
        }
        return payload
    }
}
