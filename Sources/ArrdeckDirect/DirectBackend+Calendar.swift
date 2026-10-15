import ArrdeckData
import Foundation

extension DirectBackend: CalendarAPI {
    public func calendar(start: String, days: Int) async throws -> [ArrApp: Block<[CalendarItem]>] {
        throw APIError.needsServer
    }
}
