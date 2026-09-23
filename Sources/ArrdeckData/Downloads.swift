import ArrdeckAPI
import Foundation

public typealias TorrentGroup = Components.Schemas.TorrentGroupOut
public typealias TorrentDetails = Components.Schemas.TorrentDetailsOut
public typealias TorrentFile = Components.Schemas.TorrentFileOut
public typealias Tracker = Components.Schemas.TrackerOut

extension Components.Schemas.ServiceBlock_TorrentGroupOut_: ServiceBlockShape {}

extension Torrent {
    /// Stable across both clients: qBittorrent ids are hashes, Transmission's
    /// are small integers, so the client has to be part of the key.
    public var key: String { "\(client.rawValue)-\(id)" }

    /// What "pause" would be a no-op on. `completed` is qBittorrent's paused-
    /// after-finishing state; resume turns it back into seeding.
    public var isPaused: Bool { state == "paused" || state == "completed" }

    public var torrentClient: TorrentClient {
        TorrentClient(rawValue: client.rawValue) ?? .qbittorrent
    }
}

/// The columns the list can be ordered by, named as the backend's query wants
/// them.
public enum TorrentSort: String, CaseIterable, Sendable, Hashable {
    case addedOn = "added_on"
    case name
    case state
    case progress
    case size
    case dlSpeed = "dl_speed"
    case eta
    case ratio
    case uploaded
    case tracker

    public var label: String {
        switch self {
        case .addedOn: String(localized: "Added")
        case .name: String(localized: "Name")
        case .state: String(localized: "State")
        case .progress: String(localized: "Progress")
        case .size: String(localized: "Size")
        case .dlSpeed: String(localized: "Speed")
        case .eta: String(localized: "ETA")
        case .ratio: String(localized: "Ratio")
        case .uploaded: String(localized: "Uploaded")
        case .tracker: String(localized: "Indexer")
        }
    }

    enum Value {
        case text(String)
        case number(Double)
    }

    func value(of torrent: Torrent) -> Value? {
        switch self {
        case .addedOn: torrent.added_on.map { .number(Double($0)) }
        case .name: .text(torrent.name)
        case .state: .text(torrent.state)
        case .progress: .number(torrent.progress)
        case .size: .number(Double(torrent.size))
        case .dlSpeed: .number(Double(torrent.dl_speed))
        case .eta: torrent.eta.map { .number(Double($0)) }
        case .ratio: torrent.ratio.map { .number($0) }
        case .uploaded: torrent.uploaded.map { .number(Double($0)) }
        case .tracker: torrent.tracker.map { .text($0) }
        }
    }
}

/// What the server is asked for. Filtering and sorting happen there: the
/// stack holds ~1,900 torrents and shipping all of them every 5s cost hundreds
/// of MB an hour. Each client is capped independently, which is still correct
/// once both lists are merged — an item in the overall top N is in its own
/// client's top N too.
public struct TorrentQuery: Equatable, Sendable {
    public var text = ""
    /// nil means every state.
    public var state: String?
    public var sort: TorrentSort = .addedOn
    public var descending = true
    public var limit = 200

    public init(
        text: String = "", state: String? = nil, sort: TorrentSort = .addedOn,
        descending: Bool = true, limit: Int = 200
    ) {
        self.text = text
        self.state = state
        self.sort = sort
        self.descending = descending
        self.limit = limit
    }
}

public enum BulkTorrentAction: Sendable, Equatable {
    case pause, resume, delete(deleteData: Bool)
}

public enum TorrentSorting {
    /// The backend's comparator, so a server-limited page and the client's
    /// re-sort of the merged lists agree. Missing values sort last in *both*
    /// directions — the direction flip applies only between two present
    /// values — and text compares case-insensitively.
    public static func sort(_ torrents: [Torrent], by key: TorrentSort, descending: Bool) -> [Torrent] {
        torrents.sorted { a, b in
            switch (key.value(of: a), key.value(of: b)) {
            case (nil, nil): return false
            case (nil, _): return false
            case (_, nil): return true
            case let (x?, y?): return descending ? less(y, x) : less(x, y)
            }
        }
    }

    private static func less(_ a: TorrentSort.Value, _ b: TorrentSort.Value) -> Bool {
        switch (a, b) {
        case let (.text(x), .text(y)): x.lowercased() < y.lowercased()
        case let (.number(x), .number(y)): x < y
        case (.text, .number): true
        case (.number, .text): false
        }
    }
}

extension Motion {
    /// The full list carries every state, so judge those and the totals.
    public static func torrentsMoving(_ blocks: [TorrentClient: Block<TorrentGroup>]) -> Bool {
        blocks.values.contains { block in
            guard let group = block.value else { return false }
            if group.totals.dl_speed > 0 { return true }
            return (group.states ?? []).contains { movingStates.contains($0) }
        }
    }
}

extension Format {
    /// "45s", "12m", "3h 20m", "2d" — the arrs' remaining-time estimate.
    public static func eta(_ seconds: Int?) -> String {
        guard let seconds else { return "—" }
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(Int((Double(seconds) / 60).rounded()))m" }
        if seconds < 86400 {
            return "\(seconds / 3600)h \(Int((Double(seconds % 3600) / 60).rounded()))m"
        }
        return "\(seconds / 86400)d"
    }

    /// A torrent's added-on time, as a short day: "Sep 18".
    public static func epochDay(_ seconds: Int?, calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard let seconds, seconds > 0 else { return "—" }
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        return date.formatted(
            Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
                .month(.abbreviated).day()
        )
    }
}
