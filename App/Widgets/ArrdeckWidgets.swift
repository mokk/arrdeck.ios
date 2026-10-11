import SwiftUI
import WidgetKit

/// The widget extension. It reads the snapshot the app writes into the shared
/// App Group container and nothing else: no network, no credentials. Without
/// the App Group (a signature that cannot grant it) every widget says
/// "Open arrdeck to load", and the Live Activity, which needs no container,
/// works regardless.
@main
struct ArrdeckWidgets: WidgetBundle {
    var body: some Widget {
        DownloadingWidget()
        TodayWidget()
        FreeSpaceWidget()
        DownloadsActivityWidget()
    }
}
