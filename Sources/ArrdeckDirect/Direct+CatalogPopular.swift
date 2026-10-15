import ArrdeckData
import Foundation

/// What is being downloaded right now, per indexer, ported from the server's
/// popular.py. Torznab has no "trending", so this is the newest releases
/// ranked by the indexer's own grab count. Prowlarr caps a search at 100
/// results and ignores an offset, so one movies-and-TV query reaches back a
/// few hours on a busy tracker; asking each sub-category separately is what
/// makes a day reachable at all.
///
/// The server refreshed a stored snapshot hourly in the background. Here it
/// is built when the page asks and kept an hour, which costs the first
/// visitor of each hour the wait the server's first boot cost.
enum CatalogPopular {
    static let storedHours = 24
    /// Kept deep enough that the page can slice any limit.
    static let storedLimit = 50
    static let refresh: TimeInterval = 3600
    /// Prowlarr sends each of these on to the tracker, so the pressure stays modest.
    static let concurrency = 4
    static let perQuery = 100

    static let movies = 2000 ..< 3000
    static let tv = 5000 ..< 6000

    static func kind(_ categories: [Int]) -> String {
        if categories.contains(where: movies.contains) { return "movie" }
        if categories.contains(where: tv.contains) { return "tv" }
        return ""
    }

    /// Sub-categories where the indexer has them, roots otherwise: asking for
    /// Movies returns the 100 newest across all of them, asking for
    /// Movies/HD and Movies/WEB-DL separately 100 of each.
    static func queryCategories(_ indexer: JSON) -> [Int] {
        indexer["capabilities"]["categories"].array.flatMap { category -> [Int] in
            guard let root = category["id"].int, movies.contains(root) || tv.contains(root) else { return [] }
            let subs = category["subCategories"].array.compactMap { $0["id"].int }
            return subs.isEmpty ? [root] : subs
        }
    }

    static func describe(_ release: JSON) -> PopularRelease {
        let categories = release["categories"].array
        return PopularRelease(
            category: categories.compactMap { ($0["name"]).nonEmpty }.first,
            grabs: release["grabs"].int ?? 0,
            guid: release["guid"].nonEmpty ?? release["downloadUrl"].nonEmpty ?? "",
            indexer_id: release["indexerId"].int ?? 0, info_url: release["infoUrl"].string,
            kind: kind(categories.compactMap { $0["id"].int }), leechers: release["leechers"].int ?? 0,
            published: release["publishDate"].string, seeders: release["seeders"].int ?? 0,
            size: release["size"].int ?? 0, title: release["title"].string ?? ""
        )
    }

    /// One indexer's releases inside the window, each once (a release comes
    /// under every sub-category it is tagged with), most grabbed first.
    static func rank(_ indexer: JSON, _ pages: [[JSON]], since cutoff: Date, limit: Int) -> PopularIndexer {
        var seen: Set<String> = []
        var kept: [JSON] = []
        for row in pages.joined() {
            guard let published = row["publishDate"].date, published >= cutoff else { continue }
            let key = row["downloadUrl"].nonEmpty ?? row["guid"].nonEmpty ?? row["title"].string ?? ""
            if seen.insert(key).inserted { kept.append(row) }
        }
        let ranked = kept.sorted {
            ($0["grabs"].int ?? 0, $0["seeders"].int ?? 0) > ($1["grabs"].int ?? 0, $1["seeders"].int ?? 0)
        }
        return PopularIndexer(
            indexer: indexer["name"].string ?? "", indexer_id: indexer["id"].int ?? 0,
            releases: ranked.prefix(limit).map(describe), scanned: kept.count
        )
    }

    /// Every enabled indexer's movie and TV sub-categories, a few at a time.
    /// The expensive part: around ten real tracker queries per indexer.
    static func collect(_ prowlarr: KeyedClient, hours: Int, limit: Int, now: Date = .now) async throws -> PopularSnapshot {
        let indexers = try await prowlarr.get("/indexer").array.filter { $0["enable"].bool == true && $0["id"].int != nil }
        let jobs = indexers.enumerated().flatMap { owner, indexer in
            queryCategories(indexer).map { (owner: owner, indexer: indexer["id"].int ?? 0, category: $0) }
        }
        let pages = await boundedMap(jobs, width: concurrency) { job in
            // one dead category should not empty the page
            let rows = try? await prowlarr.get("/search", query: [
                "query": "", "type": "search", "categories": String(job.category),
                "indexerIds": String(job.indexer), "limit": String(perQuery),
            ], timeout: 90).array
            return rows ?? []
        }
        let cutoff = now.addingTimeInterval(-Double(hours) * 3600)
        return PopularSnapshot(
            generated_at: Int(now.timeIntervalSince1970), hours: hours,
            indexers: indexers.enumerated().map { owner, indexer in
                let mine = jobs.indices.filter { jobs[$0].owner == owner }.map { pages[$0] }
                return rank(indexer, mine, since: cutoff, limit: limit)
            }
        )
    }

    static func sliced(_ snapshot: PopularSnapshot, limit: Int) -> PopularSnapshot {
        var snapshot = snapshot
        snapshot.indexers = snapshot.indexers?.map { indexer in
            var indexer = indexer
            indexer.releases = indexer.releases.map { Array($0.prefix(limit)) }
            return indexer
        }
        return snapshot
    }
}

extension DirectBackend {
    /// The day's snapshot, built at most hourly; any other window is built
    /// live, which is slow — the page only ever asks for the day.
    func catalogPopular(hours: Int, limit: Int) async -> Block<PopularSnapshot> {
        let limit = max(1, min(limit, CatalogPopular.storedLimit))
        return await guarded("popular:\(hours):\(limit)") {
            let prowlarr = try registry.arr("prowlarr")
            guard hours == CatalogPopular.storedHours else {
                return try await CatalogPopular.collect(prowlarr, hours: hours, limit: limit)
            }
            let snapshot = try await cached("popular_snapshot", ttl: CatalogPopular.refresh) {
                try await CatalogPopular.collect(prowlarr, hours: hours, limit: CatalogPopular.storedLimit)
            }
            return CatalogPopular.sliced(snapshot, limit: limit)
        }
    }
}
