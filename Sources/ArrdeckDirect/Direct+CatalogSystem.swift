import ArrdeckData
import Foundation

/// The arrs' own housekeeping, as the System page shows it: their scheduled
/// tasks, their backups and their quality profiles. Ported from the server's
/// tasks.py and profiles.py; the fetching is in `DirectBackend+Manage.swift`.
enum CatalogSystem {
    /// The arrs whose tasks and backups the page lists, in its order.
    static let taskApps = ["radarr", "sonarr", "prowlarr"]

    // MARK: Tasks

    /// The tasks worth showing before the card is expanded. Everything else
    /// is bookkeeping nobody asks about, or runs so often that its last run
    /// says nothing.
    static let notableTasks: Set = [
        "RssSync", "ImportListSync", "RefreshMovie", "RefreshSeries", "CheckHealth", "Backup",
        "ApplicationIndexerSync",
    ]

    /// Being a little late is normal — the arrs queue tasks behind each
    /// other. The grace grows with the interval, so a one-minute task is not
    /// flagged for a 30-second slip, and is capped, so a weekly backup does
    /// not get days of leeway.
    static func grace(intervalMinutes: Int) -> TimeInterval {
        min(max(Double(intervalMinutes) * 60 / 2, 120), 1800)
    }

    /// The arrs write durations as HH:MM:SS.fffffff.
    static func duration(_ raw: String?) -> Double? {
        guard let parts = raw?.split(separator: ":", omittingEmptySubsequences: false), parts.count == 3,
              let hours = Int(parts[0]), let minutes = Int(parts[1]), let seconds = Double(parts[2])
        else { return nil }
        return Double(hours * 3600 + minutes * 60) + seconds
    }

    static func task(app: String, _ raw: JSON, now: Date) -> ScheduledTask {
        let name = raw["taskName"].nonEmpty ?? raw["name"].nonEmpty ?? ""
        let interval = raw["interval"].double.map { Int($0) } ?? 0
        let next = raw["nextExecution"].date
        let late = next.map { now.timeIntervalSince($0) } ?? 0
        // an interval of 0 is "disabled", a choice rather than a failure
        let overdue = interval != 0 && next != nil && late > grace(intervalMinutes: interval)
        return ScheduledTask(
            app: app, interval_minutes: interval, label: raw["name"].nonEmpty ?? name,
            last_duration_seconds: duration(raw["lastDuration"].string),
            last_execution: raw["lastExecution"].string, name: name, next_execution: raw["nextExecution"].string,
            notable: notableTasks.contains(name), overdue: overdue,
            overdue_by_seconds: overdue ? (late * 10).rounded() / 10 : nil
        )
    }

    /// Overdue first, then the soonest next run: the reason to open the card
    /// is always something being late.
    static func tasks(_ perApp: [(String, [JSON])], now: Date = .now) -> [ScheduledTask] {
        perApp.flatMap { app, raws in raws.map { task(app: app, $0, now: now) } }
            .sorted { a, b in
                let (lateA, lateB) = (a.overdue == true, b.overdue == true)
                if lateA != lateB { return lateA }
                return (a.next_execution ?? "9999") < (b.next_execution ?? "9999")
            }
    }

    // MARK: Backups

    /// Newest first. `base` is the arr's own address: a backup is served off
    /// its root, so the link is one a browser can follow.
    static func backups(_ perApp: [(String, base: String, [JSON])]) -> [ArrBackup] {
        perApp.flatMap { app, base, raws in
            raws.map { raw in
                let path = raw["path"].string ?? ""
                return ArrBackup(
                    app: app, kind: raw["type"].string ?? "", name: raw["name"].string ?? "",
                    size_bytes: raw["size"].double.map { Int($0) } ?? 0, time: raw["time"].string,
                    url: path.isEmpty ? nil : base + path
                )
            }
        }
        .sorted { ($0.time ?? "") > ($1.time ?? "") }
    }

    // MARK: Quality profiles

    /// The cutoff by name, resolved against the profile's own items. Groups
    /// and qualities share the field but not the id space (groups start at
    /// 1000), so a group is matched as a group.
    static func cutoffName(_ profile: JSON) -> String? {
        guard let cutoff = profile["cutoff"].int else { return nil }
        for item in profile["items"].array {
            let quality = item["quality"]
            if !quality.object.isEmpty, quality["id"].int == cutoff { return quality["name"].string }
            if !item["items"].array.isEmpty, item["id"].int == cutoff { return item["name"].string }
        }
        return nil
    }

    /// Best first, the way the arr's own page lists them; the API sends them
    /// worst first.
    static func items(_ profile: JSON) -> [QualityItem] {
        let cutoff = profile["cutoff"].int
        return profile["items"].array.map { item in
            let quality = item["quality"]
            if !quality.object.isEmpty {
                return QualityItem(
                    name: quality["name"].string ?? "", allowed: item["allowed"].bool ?? false, isGroup: false,
                    members: [], isCutoff: quality["id"].int == cutoff
                )
            }
            return QualityItem(
                name: item["name"].string ?? "", allowed: item["allowed"].bool ?? false, isGroup: true,
                members: item["items"].array.compactMap { ($0["quality"]["name"]).nonEmpty },
                isCutoff: item["id"].int == cutoff
            )
        }
        .reversed()
    }

    struct QualityItem: Equatable {
        var name: String
        var allowed: Bool
        var isGroup: Bool
        var members: [String]
        var isCutoff: Bool
    }

    /// The formats that move a release's score. A zero means defined but
    /// without influence, which every format is by default; listing those
    /// would bury the ones that matter.
    static func formatScores(_ profile: JSON, names: [Int: String]) -> [(name: String, score: Int)] {
        profile["formatItems"].array
            .compactMap { format -> (name: String, score: Int)? in
                let score = format["score"].int ?? 0
                guard score != 0 else { return nil }
                let id = format["format"].int
                let name = id.flatMap { names[$0] } ?? format["name"].nonEmpty ?? id.map(String.init) ?? ""
                return (name, score)
            }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.name < $1.name }
    }

    /// The custom formats and size table are context: when either fails the
    /// profiles still show, by format id and without the table.
    static func qualityProfiles(profiles: [JSON], formats: [JSON], definitions: [JSON]) -> QualityProfiles {
        var names: [Int: String] = [:]
        for format in formats {
            if let id = format["id"].int { names[id] = format["name"].string ?? "" }
        }
        let weighted = definitions.sorted { ($0["weight"].double ?? 0) < ($1["weight"].double ?? 0) }
        return QualityProfiles(
            custom_formats: formats.map { $0["name"].string ?? "" }.sorted(),
            profiles: profiles.compactMap { profile in
                guard let id = profile["id"].int else { return nil }
                return QualityProfileDetail(
                    cutoff: cutoffName(profile),
                    format_scores: formatScores(profile, names: names).map { .init(name: $0.name, score: $0.score) },
                    id: id,
                    items: items(profile).map {
                        .init(allowed: $0.allowed, is_cutoff: $0.isCutoff, is_group: $0.isGroup, members: $0.members,
                              name: $0.name)
                    },
                    min_format_score: profile["minFormatScore"].int ?? 0,
                    name: profile["name"].string ?? "", upgrade_allowed: profile["upgradeAllowed"].bool ?? false
                )
            },
            quality_definitions: weighted.map { definition in
                .init(
                    max_size: definition["maxSize"].double, min_size: definition["minSize"].double,
                    name: definition["title"].nonEmpty ?? definition["quality"]["name"].string ?? "",
                    preferred_size: definition["preferredSize"].double
                )
            }
        )
    }
}
