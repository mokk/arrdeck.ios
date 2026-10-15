import ArrdeckData
import Foundation

extension DirectBackend: ActivityAPI {
    public func activitySince(_ since: Date) async throws -> ActivitySince {
        throw APIError.needsServer
    }
}
