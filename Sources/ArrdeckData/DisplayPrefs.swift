import Foundation

/// How a library tab shows its titles: covers, a compact list, or a list
/// with the extra facts. Kept per tab, on this device.
public enum LibraryLayout: String, CaseIterable, Sendable, Hashable {
    case posters, list, details

    public var label: String {
        switch self {
        case .posters: String(localized: "Posters")
        case .list: String(localized: "List")
        case .details: String(localized: "Details")
        }
    }
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
