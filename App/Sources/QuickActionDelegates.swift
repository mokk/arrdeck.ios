import ArrdeckUI
import UIKit

/// Home-screen quick actions reach a SwiftUI app through UIKit: at a cold
/// launch in the scene's connection options, while running through the scene
/// delegate. Both hand the action to the router, which waits for the tabs.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication, configurationForConnecting session: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if let item = options.shortcutItem { _ = Self.route(item) }
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }

    @discardableResult
    static func route(_ item: UIApplicationShortcutItem) -> Bool {
        guard let action = LaunchAction(shortcutType: item.type) else { return false }
        LaunchRouter.shared.open(action)
        return true
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(
        _ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(AppDelegate.route(shortcutItem))
    }
}
