import ArrdeckData
import Foundation

extension DirectBackend: HistoryAPI {
    public func historyPage(_ page: Int) async throws -> HistoryPage {
        throw APIError.needsServer
    }

    public func blocklist() async throws -> BlocklistPage {
        throw APIError.needsServer
    }

    public func removeFromBlocklist(_ app: ArrApp, id: Int) async throws {
        throw APIError.needsServer
    }

    public func clearBlocklist(_ app: ArrApp) async throws {
        throw APIError.needsServer
    }
}
