import ArrdeckData
import Foundation

extension DirectBackend: IndexerAddAPI {
    public func indexerSchemas() async throws -> [IndexerSchema] {
        throw APIError.needsServer
    }

    public func testNewIndexer(schema: String, displayName: String, values: [String: IndexerFieldValue]) async throws {
        throw APIError.needsServer
    }

    public func addIndexer(schema: String, displayName: String, values: [String: IndexerFieldValue]) async throws {
        throw APIError.needsServer
    }
}
