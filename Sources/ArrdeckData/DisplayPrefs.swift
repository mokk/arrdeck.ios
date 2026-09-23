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

/// Dates as "3 days ago" or as a date.
public enum DateStyle: String, CaseIterable, Sendable {
    case relative, absolute

    public var label: String {
        switch self {
        case .relative: String(localized: "Relative (3 days ago)")
        case .absolute: String(localized: "Dates (Sep 20)")
        }
    }
}

/// 1 GB as 1024 MB (what arrdeck always showed) or 1000 MB, as disks are sold.
public enum SizeStyle: String, CaseIterable, Sendable {
    case binary, decimal

    public var label: String {
        switch self {
        case .binary: "1 GB = 1024 MB"
        case .decimal: "1 GB = 1000 MB"
        }
    }
}

/// Hide what episodes are called and about: never, until watched, or always.
public enum Spoilers: String, CaseIterable, Sendable {
    case off, unwatched, always

    public var label: String {
        switch self {
        case .off: String(localized: "Off")
        case .unwatched: String(localized: "Unwatched episodes")
        case .always: String(localized: "All episodes")
        }
    }
}

/// Which actions ask first. Deleting a title always asks whether to keep the
/// files, since that is a choice rather than a confirmation.
public enum ConfirmPolicy: String, CaseIterable, Sendable {
    case always, deletes, never

    public var label: String {
        switch self {
        case .always: String(localized: "Every action")
        case .deletes: String(localized: "Deleting only")
        case .never: String(localized: "Never")
        }
    }

    public func asks(destructive: Bool) -> Bool {
        switch self {
        case .always: true
        case .deletes: destructive
        case .never: false
        }
    }
}

/// The UserDefaults keys the views bind with @AppStorage.
public enum DisplayKeys {
    public static func layout(_ app: ArrApp) -> String { "display.layout.\(app.rawValue)" }
    public static func unmonitored(_ app: ArrApp) -> String { "display.unmonitored.\(app.rawValue)" }
    public static let startTab = "display.startTab"
    /// comma-separated AppTab raw values
    public static let tabOrder = "display.tabOrder"
    public static let hiddenTabs = "display.hiddenTabs"
    public static let dates = "display.dates"
    public static let sizes = "display.sizes"
    public static let spoilers = "display.spoilers"
    public static let confirm = "display.confirm"
}

extension UserDefaults {
    /// A stored preference, or its default when unset or unknown.
    public func pref<T: RawRepresentable>(_ key: String, default value: T) -> T where T.RawValue == String {
        string(forKey: key).flatMap(T.init(rawValue:)) ?? value
    }
}
