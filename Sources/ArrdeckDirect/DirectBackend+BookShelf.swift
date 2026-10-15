import ArrdeckData
import Foundation

extension DirectBackend: BookShelfAPI {
    public func bookShelf() async throws -> [ShelfSeries] {
        throw APIError.needsServer
    }
}
