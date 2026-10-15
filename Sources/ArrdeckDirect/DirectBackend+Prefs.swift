import ArrdeckData
import Foundation

extension DirectBackend: PrefsAPI {
    public func prefs() async throws -> StoredPrefs {
        throw APIError.needsServer
    }

    public func putPrefs(values: [String: PrefValue], updatedAt: Int) async throws -> StoredPrefs {
        throw APIError.needsServer
    }
}
