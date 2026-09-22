import ArrdeckKit
import ArrdeckUI
import SwiftUI

/// Kept to the minimum that cannot be compile-checked without Xcode: everything
/// with behaviour lives in the package, where `./test.sh` reaches it.
@main
struct ArrdeckApp: App {
    init() {
        // UI tests start from a clean slate. The Keychain outlives an uninstall
        // on the simulator, and with one saved server the app would open
        // straight into its dashboard instead of the list the test drives.
        if CommandLine.arguments.contains("--reset-profiles") {
            try? KeychainProfileStore().save([])
        }
    }

    var body: some Scene {
        WindowGroup {
            ProfileListView()
        }
    }
}
