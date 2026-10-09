import ArrdeckData
import ArrdeckKit
import Observation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import UserNotifications

/// Where the app was asked to go from outside it: a home-screen quick action
/// or a Siri / Shortcuts "open" intent. Either can arrive before any server is
/// on screen — at a cold launch the profiles, the session and /services all
/// load first — so the request waits here until the tabs exist to take it.
public enum LaunchAction: String, CaseIterable, Sendable {
    case add, search, activity, calendar

    static let typePrefix = "dk.thrawn.arrdeck."

    /// From a quick action's type, "dk.thrawn.arrdeck.activity".
    public init?(shortcutType: String) {
        guard shortcutType.hasPrefix(Self.typePrefix) else { return nil }
        self.init(rawValue: String(shortcutType.dropFirst(Self.typePrefix.count)))
    }

    var shortcutType: String { Self.typePrefix + rawValue }

    var title: String {
        switch self {
        case .add: String(localized: "Add")
        case .search: String(localized: "Search")
        case .activity: String(localized: "Activity")
        case .calendar: String(localized: "Calendar")
        }
    }

    var symbol: String {
        switch self {
        case .add: "plus"
        case .search: "magnifyingglass"
        case .activity: AppTab.activity.symbol
        case .calendar: AppTab.calendar.symbol
        }
    }

    /// What this server can do of the four: Add and Search need an arr, the
    /// others their tab.
    static func available(tabs: [AppTab], hasArr: Bool) -> [LaunchAction] {
        allCases.filter { action in
            switch action {
            case .add, .search: hasArr
            case .activity: tabs.contains(.activity)
            case .calendar: tabs.contains(.calendar)
            }
        }
    }
}

@MainActor @Observable
public final class LaunchRouter {
    public static let shared = LaunchRouter()
    public private(set) var pending: LaunchAction?

    public func open(_ action: LaunchAction) { pending = action }

    func take() -> LaunchAction? {
        defer { pending = nil }
        return pending
    }
}

enum QuickActions {
    /// The long-press menu on the icon, kept to what the open server has.
    /// Dynamic rather than in Info.plist so a stack without Sonarr never
    /// offers a Calendar that would open nothing.
    @MainActor static func update(_ actions: [LaunchAction]) {
        #if canImport(UIKit)
        UIApplication.shared.shortcutItems = actions.map { action in
            UIApplicationShortcutItem(
                type: action.shortcutType, localizedTitle: action.title, localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: action.symbol), userInfo: nil
            )
        }
        #endif
    }
}

/// A local notification the day before the signature runs out — the warning
/// that reaches you without opening the app. Local, so it needs neither push
/// nor a paid developer account.
enum ExpiryReminder {
    static let identifier = "signing-expiry"
    static let lead: TimeInterval = 24 * 3600

    static func schedule(_ expiry: Date, now: Date = .now) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        let fireIn = expiry.timeIntervalSince(now) - lead
        // already inside the last day: the in-app strip is the warning now
        guard fireIn > 60 else { return }
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "arrdeck expires tomorrow")
        content.body = String(localized: "Reinstall it from your Mac to keep it opening.")
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fireIn, repeats: false)
        try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }
}

/// Floating above the tab bar in the signature's last two days.
struct ExpiryStrip: View {
    let expiry: Date

    var body: some View {
        Label {
            Text("arrdeck stops opening \(expiry, format: .relative(presentation: .named)). Reinstall it from your Mac.")
        } icon: {
            Image(systemName: "clock.badge.exclamationmark")
        }
        .font(.caption)
        .foregroundStyle(Color.warning)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .liquidGlassCapsule()
        .padding(.horizontal, 20)
        .accessibilityIdentifier("expiry-strip")
    }
}
