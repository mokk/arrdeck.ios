import Foundation

/// How a library tab shows its titles: covers, a compact list, or a list
/// with the extra facts. Kept per tab, on this device.
public enum LibraryLayout: String, CaseIterable, Sendable, Hashable {
    case posters, list, details
    /// Shows in airing order; books as series with their gaps; Radarr's collections.
    case upNext = "upnext", shelf, collections

    public var label: String {
        switch self {
        case .posters: String(localized: "Posters")
        case .list: String(localized: "List")
        case .details: String(localized: "Details")
        case .upNext: String(localized: "Up next")
        case .shelf: String(localized: "Bookshelf")
        case .collections: String(localized: "Collections")
        }
    }

    /// Each tab's views: the three shared layouts, then the one only that kind has.
    public static func options(for app: ArrApp) -> [LibraryLayout] {
        switch app {
        case .radarr: [.posters, .list, .details, .collections]
        case .sonarr: [.posters, .list, .details, .upNext]
        case .readarr: [.posters, .list, .details, .shelf]
        }
    }

    /// The views that bring their own order, so sort and the letter strip do not apply.
    public var ownsOrder: Bool { self == .upNext || self == .shelf || self == .collections }
}

/// What to do with titles nobody is monitoring.
public enum UnmonitoredMode: String, CaseIterable, Sendable, Hashable {
    case show, dim, hide

    public var label: String {
        switch self {
        case .show: String(localized: "Show")
        case .dim: String(localized: "Dim")
        case .hide: String(localized: "Hide")
        }
    }
}

/// The UserDefaults keys the views bind with @AppStorage, one per tab.
public enum DisplayKeys {
    public static func layout(_ app: ArrApp) -> String { "display.layout.\(app.rawValue)" }
    public static func unmonitored(_ app: ArrApp) -> String { "display.unmonitored.\(app.rawValue)" }
}
