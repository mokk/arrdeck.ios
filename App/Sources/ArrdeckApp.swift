import ArrdeckKit
import ArrdeckUI
import Foundation
import SwiftUI

/// Kept to the minimum that cannot be compile-checked without Xcode: everything
/// with behaviour lives in the package, where `./test.sh` reaches it.
@main
struct ArrdeckApp: App {
    // only for home-screen quick actions, which SwiftUI does not deliver
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // UI tests start from a clean slate. The Keychain outlives an uninstall
        // on the simulator, and with one saved server the app would open
        // straight into its dashboard instead of the list the test drives.
        if CommandLine.arguments.contains("--reset-profiles") {
            try? KeychainProfileStore().save([])
        }
        // and with --seed-profile, one profile with the services the test
        // runner handed over, which the app then opens straight into
        if CommandLine.arguments.contains("--seed-profile"),
           let json = ProcessInfo.processInfo.environment["ARRDECK_CONNECTIONS"] {
            ProfileListView.seed(json: Data(json.utf8))
        }
    }

    var body: some Scene {
        WindowGroup {
            ProfileListView()
                // a tap on a widget or the Live Activity: the tab it shows
                .onOpenURL { url in AppDelegate.route(url) }
        }
    }
}
