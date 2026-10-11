import ArrdeckUI
import UIKit

/// Home-screen quick actions reach a SwiftUI app through UIKit: at a cold
/// launch in the scene's connection options, while running through the scene
/// delegate. Both hand the action to the router, which waits for the tabs.
/// A widget's link takes the same two routes (and SwiftUI's onOpenURL as
/// well, since a custom scene delegate may take the URL before SwiftUI sees
/// it); opening the same tab twice is harmless.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication, configurationForConnecting session: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if let item = options.shortcutItem { _ = Self.route(item) }
        for context in options.urlContexts { Self.route(context.url) }
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

    @discardableResult
    static func route(_ url: URL) -> Bool {
        guard let action = LaunchAction(url: url) else { return false }
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

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts { AppDelegate.route(context.url) }
    }
}
