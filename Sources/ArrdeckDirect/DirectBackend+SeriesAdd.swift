import ArrdeckData
import Foundation

/// Adding a show with a choice of what Sonarr monitors, ported from the
/// server's discover.py (`season_numbers`, `series_payload`, `add_series`).
extension DirectBackend: SeriesAddAPI {
    public func seriesSeasons(tvdbID: Int) async throws -> [Int] {
        try await call { try await seasonNumbers(try registry.arr("sonarr"), tvdbID: tvdbID) }
    }

    public func addSeries(
        _ result: SearchResult, qualityProfile: Int, rootFolder: String, monitor: SeriesMonitor, seasons: [Int]?
    ) async throws {
        try await call {
            let sonarr = try registry.arr("sonarr")
            // a pick has to name every season, so the show is looked up first
            let numbers = seasons == nil ? [] : try await seasonNumbers(sonarr, tvdbID: result.remote_id)
            let payload = SeriesAdd.payload(
                tvdbID: result.remote_id, title: result.title, qualityProfile: qualityProfile, rootFolder: rootFolder,
                monitor: monitor, seasons: seasons, seasonNumbers: numbers
            )
            try await sonarr.send("POST", "/series", json: payload)
            catalogForget("library_map:series")
        }
    }

    /// Every season number the lookup knows, specials included. The lookup
    /// can answer with near matches, so the one with this TVDB id is taken,
    /// the first otherwise.
    private func seasonNumbers(_ sonarr: KeyedClient, tvdbID: Int) async throws -> [Int] {
        let found = try await sonarr.get("/series/lookup", query: ["term": "tvdb:\(tvdbID)"]).array
        let match = found.first { $0["tvdbId"].int == tvdbID } ?? found.first ?? .null
        return Set(match["seasons"].array.compactMap { $0["seasonNumber"].int }).sorted()
    }
}

enum SeriesAdd {
    /// Sonarr's add call. Picked seasons go as Sonarr's own season list with
    /// monitoring set per season, and `skip` so Sonarr leaves that as it is;
    /// a preset goes through as Sonarr's own monitor option, and with
    /// neither Sonarr's default stands.
    static func payload(
        tvdbID: Int, title: String, qualityProfile: Int, rootFolder: String, monitor: SeriesMonitor, seasons: [Int]?,
        seasonNumbers: [Int]
    ) -> JSON {
        var options: [String: JSON] = [
            "searchForMissingEpisodes": .bool(SeriesMonitorPick.searches(monitor: monitor, seasons: seasons)),
        ]
        var payload: [String: JSON] = [
            "tvdbId": JSON(tvdbID), "title": .string(title), "qualityProfileId": JSON(qualityProfile),
            "rootFolderPath": .string(rootFolder), "monitored": true, "seasonFolder": true,
        ]
        if let seasons {
            let chosen = Set(seasons)
            payload["seasons"] = .array(seasonNumbers.map { ["seasonNumber": JSON($0), "monitored": .bool(chosen.contains($0))] })
            options["monitor"] = "skip"
        } else if monitor != .pick {
            options["monitor"] = .string(monitor.rawValue)
        }
        payload["addOptions"] = .object(options)
        return .object(payload)
    }
}
