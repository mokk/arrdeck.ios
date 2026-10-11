import ArrdeckAPI

// The server names services and arrs in plain strings, and a newer server
// names ones this build has never heard of. Scripts/derive-spec.jq turns
// every `app` and `service` enum in the answers into a string, so the
// generated client decodes whatever arrives; this file is where those
// strings become ArrApp or a known service, and where a row naming
// something else is dropped, so one unknown name costs that row and no
// more. Every LiveAPI method that returns such rows filters here.

/// A row that says which arr it came from.
public protocol ArrNamed {
    var app: String { get }
}

extension ArrNamed {
    /// nil for an arr this build does not know; such a row never gets past
    /// LiveAPI, so code downstream can treat nil as impossible-but-handled.
    public var arr: ArrApp? { ArrApp(rawValue: app) }
}

extension QueueItem {
    /// Ids are each arr's own, so a list mixing arrs keys its rows by both.
    public var rowID: String { "\(app)-\(id)" }
}

extension BlocklistItem {
    /// Ids are each arr's own, so a list mixing arrs keys its rows by both.
    public var rowID: String { "\(app)-\(id)" }
}

extension QueueItem: ArrNamed {}
extension CalendarItem: ArrNamed {}
extension HistoryItem: ArrNamed {}
extension RecentItem: ArrNamed {}
extension WantedItem: ArrNamed {}
extension BlocklistItem: ArrNamed {}
extension Exclusion: ArrNamed {}

extension Array where Element: ArrNamed {
    /// The rows from arrs this build knows.
    public var fromKnownArrs: [Element] { filter { $0.arr != nil } }
}

extension Block {
    public func map<T>(_ transform: (Value) -> T) -> Block<T> {
        switch self {
        case let .healthy(value): .healthy(transform(value))
        case let .stale(value, age): .stale(transform(value), age: age)
        case let .offline(reason): .offline(reason)
        }
    }

    /// The same slice without the rows from arrs this build does not know.
    public func fromKnownArrs<Element: ArrNamed>() -> Block<[Element]> where Value == [Element] {
        map(\.fromKnownArrs)
    }
}

extension Services {
    /// Every service this build can name. A status row or a /services entry
    /// for anything else is skipped rather than shown under a raw name.
    public static let known: Set<String> = [
        "radarr", "sonarr", "readarr", "lidarr", "prowlarr", "qbittorrent", "transmission",
        "overseerr", "gluetun", "bazarr", "plex", "prometheus", "trakt", "helper",
    ]
}
