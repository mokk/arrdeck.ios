import ArrdeckData
import Foundation

extension DirectBackend: HistoryAPI {
    /// History merged across the arrs, 50 records an arr a page, each
    /// release once. An arr that is down leaves its rows out, not the page.
    public func historyPage(_ page: Int) async throws -> HistoryPage {
        let apps = dashboardListedArrs()
        let pages = await withTaskGroup(of: (ArrApp, JSON?).self) { group in
            for app in apps {
                group.addTask {
                    (app, try? await DashboardPort.history(try self.registry.arr(app.rawValue), app: app, pageSize: 50, page: page))
                }
            }
            var out: [ArrApp: JSON] = [:]
            for await (app, payload) in group { out[app] = payload }
            return out
        }
        var items: [HistoryItem] = []
        var hasMore = false
        for app in apps {
            guard let payload = pages[app] else { continue }
            if payload["records"].array.count >= 50 { hasMore = true }
            items += DashboardPort.consolidateHistory(app: app, payload: payload, limit: 100)
        }
        return HistoryPage(has_more: hasMore, items: DashboardPort.stableSorted(items) { $0.date > $1.date })
    }

    /// Releases blocklisted from the queue, newest first across the arrs that
    /// keep a list here: Radarr, Sonarr, and Lidarr once set up.
    public func blocklist() async throws -> BlocklistPage {
        let apps = dashboardListedArrs(Self.blocklistApps)
        let pages = await withTaskGroup(of: (ArrApp, JSON?).self) { group in
            for app in apps {
                group.addTask { (app, try? await Self.blocklistPage(try self.registry.arr(app.rawValue), page: 1)) }
            }
            var out: [ArrApp: JSON] = [:]
            for await (app, payload) in group { out[app] = payload }
            return out
        }
        var items: [BlocklistItem] = []
        var total = 0
        for app in apps {
            guard let payload = pages[app] else { continue }
            total += DashboardPort.whole(payload["totalRecords"]) ?? 0
            items += payload["records"].array.map { Self.blocklistItem(app: app, record: $0) }
        }
        return BlocklistPage(items: DashboardPort.stableSorted(items) { ($0.date ?? "") > ($1.date ?? "") }, total: total)
    }

    public func removeFromBlocklist(_ app: ArrApp, id: Int) async throws {
        try await call {
            _ = try await blocklistClient(app).send("DELETE", "/blocklist/\(id)")
        }
    }

    public func clearBlocklist(_ app: ArrApp) async throws {
        try await call {
            let client = try blocklistClient(app)
            guard app == .lidarr else {
                // Radarr and Sonarr read an empty bulk delete as "all of it"
                try await client.send("DELETE", "/blocklist/bulk", json: ["ids": []])
                return
            }
            // Lidarr's removes the ids it is given and nothing else
            var ids: [Int] = []
            var page = 1
            while true {
                let payload = try await Self.blocklistPage(client, page: page, pageSize: 1000)
                let records = payload["records"].array
                ids += records.compactMap { $0["id"].int }
                if records.isEmpty || ids.count >= (DashboardPort.whole(payload["totalRecords"]) ?? 0) { break }
                page += 1
            }
            if !ids.isEmpty { try await client.send("DELETE", "/blocklist/bulk", json: ["ids": .init(ids)]) }
        }
    }

    private static let blocklistApps: [ArrApp] = [.radarr, .sonarr, .lidarr]

    private func blocklistClient(_ app: ArrApp) throws -> KeyedClient {
        guard Self.blocklistApps.contains(app) else { throw APIError.refused("unknown app '\(app.rawValue)'") }
        return try registry.arr(app.rawValue)
    }

    private static func blocklistPage(_ client: KeyedClient, page: Int, pageSize: Int = 50) async throws -> JSON {
        try await client.get("/blocklist", query: [
            "page": String(page), "pageSize": String(pageSize), "sortKey": "date", "sortDirection": "descending",
        ])
    }

    private static func blocklistItem(app: ArrApp, record: JSON) -> BlocklistItem {
        let media = DashboardPort.truthy(record["movie"]) ? record["movie"] : record["series"]
        // Lidarr names the artist; the release title says which album
        let title = app == .lidarr ? record["artist"]["artistName"].string : media["title"].string
        return BlocklistItem(
            app: app.rawValue, date: record["date"].string, id: record["id"].int ?? 0,
            indexer: record["indexer"].string, quality: record["quality"]["quality"]["name"].string,
            source_title: record["sourceTitle"].string ?? "", title: title ?? ""
        )
    }
}
