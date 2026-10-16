import ArrdeckAPI
import Foundation

/// The bookshelf: Readarr's series for the authors in the library, each with
/// every book in it so the missing ones show.
public protocol BookShelfAPI: Sendable {
    func bookShelf() async throws -> [ShelfSeries]
}

extension ShelfSeries {
    /// Books on disk out of the whole series.
    public var have: Int { (books ?? []).filter { $0.has_file == true }.count }
    public var total: Int { books?.count ?? 0 }
}
