import Foundation

/// What to do about the server's copy of the display preferences and this
/// device's own. The PWA's rule (lib/prefsMerge.ts), so both clients settle
/// the same way. Pure, so it is testable without a network or a clock.
public enum SyncAction: Equatable, Sendable {
    /// Take the server's values.
    case apply
    /// Send this device's.
    case push
    case none
}

public enum PrefsSyncPolicy {
    /// - serverAt: the server's updated_at; 0 when nothing was ever stored there
    /// - syncedAt: the server's updated_at at the last sync this device completed; 0 = never
    /// - changedAt: when the oldest unsent local change was made; 0 = nothing waiting
    /// - hasLocalValues: whether this device has choices of its own rather than defaults
    public static func decide(serverAt: Int, syncedAt: Int, changedAt: Int, hasLocalValues: Bool) -> SyncAction {
        // Unsent changes: last write wins, whoever made it. A change made
        // offline earlier than one the server has since received loses.
        if changedAt > 0 { return serverAt > changedAt ? .apply : .push }
        if serverAt > syncedAt { return .apply }
        // Nothing waiting and the server has nothing newer. It may still have
        // nothing at all, or have been restored from an older backup; if this
        // device holds choices, they are the copy worth keeping. A device with
        // only defaults must never seed the server with them.
        if hasLocalValues && (serverAt == 0 || serverAt < syncedAt) { return .push }
        return .none
    }
}

/// How this app's display choices map onto the server's preference keys,
/// which the web app shares. Language is deliberately absent: it is chosen
/// per device.
///
/// | this app (UserDefaults)                  | wire key                          | wire value                          |
/// | display.layout.radarr/sonarr/readarr     | layout.movies/series/books        | same raw value ("upnext" included)  |
/// | display.unmonitored.radarr/sonarr/readarr| unmonitored.movies/series/books   | same                                |
/// | display.startTab  (AppTab, "" = default) | startTab                          | "/books" "/movies" "/shows" …, ""   |
/// | display.tabOrder, display.hiddenTabs     | tabOrder, hiddenTabs              | array of the same routes            |
/// | display.dates, .sizes, .spoilers,        | dates, sizes, spoilers, confirm   | same                                |
/// |   .confirm                               |                                   |                                     |
/// | display.appearance                       | theme                             | system / dark / light               |
/// | display.palette                          | palette                           | same                                |
public enum DisplaySync {
    /// The web routes of the tabs. Spelled out rather than derived: the web's
    /// are what the server holds, and `/shows` is not `/series`.
    static let routes: [AppTab: String] = [
        .books: "/books", .movies: "/movies", .shows: "/shows",
        .activity: "/activity", .calendar: "/calendar", .settings: "/settings",
    ]

    static func wireName(_ app: ArrApp) -> String {
        switch app {
        case .radarr: "movies"
        case .sonarr: "series"
        case .readarr: "books"
        }
    }

    static func tab(route: String) -> AppTab? {
        routes.first { $0.value == route }?.key
    }

    /// Every key this app reads and writes.
    public static let keys: Set<String> = {
        var keys: Set<String> = ["startTab", "tabOrder", "hiddenTabs", "dates", "sizes", "spoilers", "confirm", "theme", "palette"]
        for app in ArrApp.allCases { keys.insert("layout.\(wireName(app))"); keys.insert("unmonitored.\(wireName(app))") }
        return keys
    }()

    /// The UserDefaults key behind each synced key, for telling whether this
    /// device holds a choice of its own.
    static var storageKeys: [String] {
        var keys = [DisplayKeys.startTab, DisplayKeys.tabOrder, DisplayKeys.hiddenTabs, DisplayKeys.dates, DisplayKeys.sizes,
                    DisplayKeys.spoilers, DisplayKeys.confirm, DisplayKeys.appearance, DisplayKeys.palette]
        for app in ArrApp.allCases { keys.append(DisplayKeys.layout(app)); keys.append(DisplayKeys.unmonitored(app)) }
        return keys
    }

    /// Whether the user has chosen anything here, as opposed to running on defaults.
    public static func hasLocalValues(_ defaults: UserDefaults) -> Bool {
        storageKeys.contains { defaults.object(forKey: $0) != nil }
    }

    /// What this device would send: every synced choice, defaults included,
    /// so a reset travels too.
    public static func collect(_ defaults: UserDefaults) -> [String: PrefValue] {
        var values: [String: PrefValue] = [:]
        for app in ArrApp.allCases {
            let layout = defaults.pref(DisplayKeys.layout(app), default: LibraryLayout.posters)
            values["layout.\(wireName(app))"] = .string(LibraryLayout.options(for: app).contains(layout) ? layout.rawValue : LibraryLayout.posters.rawValue)
            values["unmonitored.\(wireName(app))"] = .string(defaults.pref(DisplayKeys.unmonitored(app), default: UnmonitoredMode.show).rawValue)
        }
        values["startTab"] = .string(AppTab(rawValue: defaults.string(forKey: DisplayKeys.startTab) ?? "").flatMap { routes[$0] } ?? "")
        values["tabOrder"] = .strings(routeList(defaults.string(forKey: DisplayKeys.tabOrder) ?? ""))
        values["hiddenTabs"] = .strings(routeList(defaults.string(forKey: DisplayKeys.hiddenTabs) ?? ""))
        values["dates"] = .string(defaults.pref(DisplayKeys.dates, default: DateStyle.relative).rawValue)
        values["sizes"] = .string(defaults.pref(DisplayKeys.sizes, default: SizeStyle.binary).rawValue)
        values["spoilers"] = .string(defaults.pref(DisplayKeys.spoilers, default: Spoilers.off).rawValue)
        values["confirm"] = .string(defaults.pref(DisplayKeys.confirm, default: ConfirmPolicy.deletes).rawValue)
        values["theme"] = .string(defaults.pref(DisplayKeys.appearance, default: Appearance.system).rawValue)
        values["palette"] = .string(defaults.pref(DisplayKeys.palette, default: Palette.arrdeck).rawValue)
        return values
    }

    /// Writes the server's values into storage, which the views and the theme
    /// pick up. A value this app cannot show (a layout only the web has, a
    /// palette from a newer version, a tab it has no screen for) is skipped,
    /// and keys the server did not send are left as they are.
    public static func apply(_ values: [String: PrefValue], to defaults: UserDefaults) {
        func store(_ key: String, _ raw: String?) {
            guard let raw, defaults.string(forKey: key) != raw else { return }
            defaults.set(raw, forKey: key)
        }
        func choice<T: RawRepresentable>(_ wire: String, _ key: String, as _: T.Type, allowed: (T) -> Bool = { _ in true }) where T.RawValue == String {
            guard let raw = values[wire]?.string, let value = T(rawValue: raw), allowed(value) else { return }
            store(key, value.rawValue)
        }
        for app in ArrApp.allCases {
            choice("layout.\(wireName(app))", DisplayKeys.layout(app), as: LibraryLayout.self) { LibraryLayout.options(for: app).contains($0) }
            choice("unmonitored.\(wireName(app))", DisplayKeys.unmonitored(app), as: UnmonitoredMode.self)
        }
        if let route = values["startTab"]?.string {
            if route.isEmpty { store(DisplayKeys.startTab, "") } else { store(DisplayKeys.startTab, tab(route: route)?.rawValue) }
        }
        if let routes = values["tabOrder"]?.strings { store(DisplayKeys.tabOrder, tabList(routes)) }
        if let routes = values["hiddenTabs"]?.strings { store(DisplayKeys.hiddenTabs, tabList(routes)) }
        choice("dates", DisplayKeys.dates, as: DateStyle.self)
        choice("sizes", DisplayKeys.sizes, as: SizeStyle.self)
        choice("spoilers", DisplayKeys.spoilers, as: Spoilers.self)
        choice("confirm", DisplayKeys.confirm, as: ConfirmPolicy.self)
        choice("theme", DisplayKeys.appearance, as: Appearance.self)
        choice("palette", DisplayKeys.palette, as: Palette.self)
    }

    /// "movies,shows" as ["/movies", "/shows"]; a tab with no route is dropped.
    static func routeList(_ stored: String) -> [String] {
        AppTab.list(stored).compactMap { routes[$0] }
    }

    /// The reverse, dropping routes this app has no tab for.
    static func tabList(_ routes: [String]) -> String {
        routes.compactMap { tab(route: $0)?.rawValue }.joined(separator: ",")
    }
}
