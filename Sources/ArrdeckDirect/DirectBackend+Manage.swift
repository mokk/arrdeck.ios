import ArrdeckData
import Foundation

extension DirectBackend: ManageAPI {
    func probeStatus(_ name: String) async -> ServiceStatus {
        do {
            let version = try await registry.probeVersion(name)
            return ServiceStatus(ok: true, retries: registry.retries.count(name), service: name, version: version)
        } catch {
            return ServiceStatus(error: Self.reason(error), ok: false, retries: registry.retries.count(name), service: name)
        }
    }

    public func libraryMovies() async throws -> [LibraryMovie] {
        throw APIError.needsServer
    }

    public func librarySeries() async throws -> [LibrarySeries] {
        throw APIError.needsServer
    }

    public func libraryBooks() async throws -> [LibraryBook] {
        throw APIError.needsServer
    }

    public func tags(_ app: ArrApp) async throws -> [LibraryTag] {
        throw APIError.needsServer
    }

    public func indexers() async throws -> [Indexer] {
        throw APIError.needsServer
    }

    public func toggleIndexer(_ id: Int, enable: Bool) async throws {
        throw APIError.needsServer
    }

    public func testIndexer(_ id: Int) async throws {
        throw APIError.needsServer
    }

    public func status() async throws -> [ServiceStatus] {
        // every configured service at once; a slow one costs its own timeout only
        await withTaskGroup(of: ServiceStatus.self) { group in
            for name in registry.configured where DirectServices.listed(name, configured: true) {
                group.addTask { await self.probeStatus(name) }
            }
            var all: [ServiceStatus] = []
            for await status in group { all.append(status) }
            let order = DirectServices.all
            return all
                .filter { Services.known.contains($0.service) }
                .sorted { (order.firstIndex(of: $0.service) ?? 0) < (order.firstIndex(of: $1.service) ?? 0) }
        }
    }

    public func tasks() async throws -> Block<[ScheduledTask]> {
        throw APIError.needsServer
    }

    public func arrBackups() async throws -> Block<[ArrBackup]> {
        throw APIError.needsServer
    }

    public func logs(_ app: String, level: String?) async throws -> [LogEntry] {
        throw APIError.needsServer
    }

    public func qualityProfiles(_ app: ArrApp) async throws -> QualityProfiles {
        throw APIError.needsServer
    }

    public func serviceSettings() async throws -> [String: ServiceSettings] {
        DirectServices.all.reduce(into: [:]) { all, name in
            let connection = registry.connection(name)
            all[name] = ServiceSettings(
                api_key: connection.apiKey, configured: registry.isConfigured(name), password: connection.password,
                url: connection.url, username: connection.username
            )
        }
    }

    public func saveServiceSettings(_ name: String, url: String, apiKey: String, username: String, password: String) async throws -> Bool {
        guard DirectServices.all.contains(name) else { throw APIError.refused("unknown service \(name)") }
        try await call {
            try registry.save(name, ServiceConnection(url: url, apiKey: apiKey, username: username, password: password))
        }
        // what was cached may belong to the old connection
        cache.clear()
        return registry.isConfigured(name)
    }

    public func testService(_ name: String) async throws -> String {
        try await call { try await registry.probeVersion(name) }
    }
}
