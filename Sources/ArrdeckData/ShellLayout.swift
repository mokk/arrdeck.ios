import Foundation

/// How the tabs are offered: the floating capsule at the bottom, or a sidebar
/// beside the content. Only a window regular in both directions gets the
/// sidebar: a wide iPad, or an unfolded iPhone Duo. A Plus or Max iPhone is
/// regular width in landscape too, but compact height, so it keeps its
/// capsule whichever way it is turned. An iPad in Slide Over or a narrow
/// Split View, or a folded iPhone Duo, is compact and looks like the phone.
public enum ShellLayout: Sendable, Equatable {
    case tabBar, sidebar

    public init(regularWidth: Bool, regularHeight: Bool) {
        self = regularWidth && regularHeight ? .sidebar : .tabBar
    }
}

/// What tapping a tab does, in the capsule and the sidebar alike.
public enum TabTap: Sendable, Equatable {
    /// Show this tab, as it was left.
    case show(AppTab)
    /// The tab already showing was tapped with a screen pushed over its first
    /// one: back to that first screen, as the system tab bar does.
    case popToRoot(AppTab)
    /// The tab already showing was tapped on its first screen.
    case nothing

    public init(_ tab: AppTab, selected: AppTab, pushed: Set<AppTab>) {
        if tab != selected {
            self = .show(tab)
        } else {
            self = pushed.contains(tab) ? .popToRoot(tab) : .nothing
        }
    }
}

extension AppTab {
    /// The tab to show from these: the current one while it is still there,
    /// otherwise the first — or Settings, which every server has.
    public static func keeping(_ selected: AppTab, in available: [AppTab]) -> AppTab {
        available.contains(selected) ? selected : available.first ?? .settings
    }
}
