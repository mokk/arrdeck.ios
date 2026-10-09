import Foundation
import Testing
@testable import ArrdeckData

struct AppLanguageTests {
    func defaults() -> UserDefaults {
        let suite = "app-language-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test func nothingChosenFollowsThePhone() {
        #expect(AppLanguage.stored(defaults()) == .system)
    }

    @Test func aLanguageIsWrittenWhereIOSReadsItAtLaunch() {
        let d = defaults()
        AppLanguage.choose(.da, defaults: d)
        #expect(AppLanguage.stored(d) == .da)
        #expect(d.stringArray(forKey: "AppleLanguages") == ["da"])
    }

    @Test func systemRemovesTheOverride() {
        let suite = "app-language-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        AppLanguage.choose(.en, defaults: d)
        #expect(d.persistentDomain(forName: suite)?["AppleLanguages"] as? [String] == ["en"])
        AppLanguage.choose(.system, defaults: d)
        #expect(AppLanguage.stored(d) == .system)
        // gone from the app's own domain, so the phone's list shows through
        #expect(d.persistentDomain(forName: suite)?["AppleLanguages"] == nil)
        d.removePersistentDomain(forName: suite)
    }

    @Test func languageNamesAreInTheirOwnLanguage() {
        #expect(AppLanguage.en.label == "English")
        #expect(AppLanguage.da.label == "Dansk")
    }
}
