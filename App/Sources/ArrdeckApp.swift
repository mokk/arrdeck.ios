import ArrdeckUI
import SwiftUI

/// Kept to the minimum that cannot be compile-checked without Xcode: everything
/// with behaviour lives in the package, where `./test.sh` reaches it.
@main
struct ArrdeckApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ProfileListView()
            }
        }
    }
}
