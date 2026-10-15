import ArrdeckData
import Foundation

extension DirectBackend: WantedAPI {
    public func wanted(_ app: ArrApp, kind: WantedKind, page: Int) async throws -> WantedPage {
        throw APIError.needsServer
    }

    public func searchAllWanted(_ app: ArrApp, kind: WantedKind) async throws {
        throw APIError.needsServer
    }

    public func diagnose(_ app: ArrApp, id: Int) async throws -> Diagnosis {
        throw APIError.needsServer
    }

    public func searchAlbum(_ id: Int) async throws {
        throw APIError.needsServer
    }
}
