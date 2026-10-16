import ArrdeckData
import SwiftUI

/// Statistics: Plex's play history — how much, who, what and when. Library
/// trends need samples taken while the app is closed, which only a server
/// can take, so they are not here.
public struct StatsScreen: View {
    let api: any WatchingAPI

    public init(api: any WatchingAPI) {
        self.api = api
    }

    public var body: some View {
        List {
            ListPageHeading(title: String(localized: "Statistics"))
            WatchingSections(api: api)
        }
        .dashboardListStyle()
        .chromePage()
        .navigationTitle("Statistics")
        .pageTitle()
        .accessibilityIdentifier("stats")
    }
}
