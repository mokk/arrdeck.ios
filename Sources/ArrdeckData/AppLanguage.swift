import Foundation

/// The app's language, chosen under Settings → Display like the PWA's picker:
/// English, Danish, or whatever the phone is set to.
///
/// iOS picks an app's localization once, at launch, from the AppleLanguages
/// list — so a choice is written there and takes effect the next time the app
/// opens. Switching live would leave the String(localized:) text built in the
/// models, the formatters and Siri's answers in the old language.
public enum AppLanguage: String, CaseIterable, Sendable {
    case system, en, da

    static let key = "display.language"
    static let appleLanguages = "AppleLanguages"

    /// The language names are written in their own language, as on the web.
    public var label: String {
        switch self {
        case .system: String(localized: "System")
        case .en: "English"
        case .da: "Dansk"
        }
    }

    public static func stored(_ defaults: UserDefaults = .standard) -> AppLanguage {
        defaults.string(forKey: key).flatMap(AppLanguage.init(rawValue:)) ?? .system
    }

    /// Records the choice and sets the app's own AppleLanguages for the next
    /// launch. System removes the override, so the phone's list shows through.
    public static func choose(_ language: AppLanguage, defaults: UserDefaults = .standard) {
        defaults.set(language.rawValue, forKey: key)
        if language == .system {
            defaults.removeObject(forKey: appleLanguages)
        } else {
            defaults.set([language.rawValue], forKey: appleLanguages)
        }
    }

    /// What the running process launched with; a different stored choice is
    /// waiting for the next launch.
    @MainActor public static let atLaunch = stored()
}
