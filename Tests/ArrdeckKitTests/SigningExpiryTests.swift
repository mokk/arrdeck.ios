import Foundation
import Testing
@testable import ArrdeckKit

struct SigningExpiryTests {
    /// The shape of a real profile — binary CMS around an XML plist — with
    /// made-up contents. Never a real one: those carry the device id and the
    /// signing certificate.
    func profile(expiring: String) -> Data {
        var data = Data([0x30, 0x80, 0x06, 0x09, 0x2A, 0x86, 0x48])
        data.append(Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Name</key><string>iOS Team Provisioning Profile: dk.thrawn.arrdeck</string>
            <key>ExpirationDate</key><date>\(expiring)</date>
        </dict>
        </plist>
        """.utf8))
        data.append(Data([0xA0, 0x82, 0x0B, 0x00, 0x00]))
        return data
    }

    @Test func readsTheExpiryOutOfTheEnvelope() {
        let date = SigningExpiry.date(fromProfile: profile(expiring: "2026-10-16T07:47:06Z"))
        #expect(date == ISO8601DateFormatter().date(from: "2026-10-16T07:47:06Z"))
    }

    @Test func somethingElseIsNoExpiry() {
        #expect(SigningExpiry.date(fromProfile: Data("not a profile".utf8)) == nil)
        #expect(SigningExpiry.date(fromProfile: Data()) == nil)
    }

    @Test func aBuildWithoutAProfileHasNoExpiry() {
        // the test bundle, like the simulator app, carries none
        #expect(SigningExpiry.current(bundle: Bundle(for: Marker.self)) == nil)
    }

    /// Against a real profile, which stays out of the repo:
    /// `ARRDECK_PROFILE=…/Arrdeck.app/embedded.mobileprovision swift test`
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ARRDECK_PROFILE"] != nil))
    func readsARealProfile() throws {
        let path = try #require(ProcessInfo.processInfo.environment["ARRDECK_PROFILE"])
        let date = try #require(SigningExpiry.date(fromProfile: try Data(contentsOf: URL(fileURLWithPath: path))))
        #expect(date > Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func warnsOnlyInTheLastTwoDays() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(!SigningExpiry.isClose(now.addingTimeInterval(3 * 86400), now: now))
        #expect(SigningExpiry.isClose(now.addingTimeInterval(36 * 3600), now: now))
        #expect(!SigningExpiry.isClose(now.addingTimeInterval(-60), now: now), "past is not running")
    }
}

private final class Marker {}

struct LastProfileTests {
    let home = ServerProfile(baseURL: URL(string: "http://10.0.0.154:3500")!, name: "Home")
    let remote = ServerProfile(baseURL: URL(string: "https://deck.example.com")!, name: "Remote")

    func defaults() -> UserDefaults {
        let suite = "last-profile-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test func theLastOpenedWins() {
        let store = defaults()
        LastProfile.record(remote, defaults: store)
        #expect(LastProfile.pick(from: [home, remote], defaults: store) == remote)
    }

    @Test func withoutARecordOnlyASingleServerIsAGuess() {
        #expect(LastProfile.pick(from: [home], defaults: defaults()) == home)
        #expect(LastProfile.pick(from: [home, remote], defaults: defaults()) == nil)
    }

    @Test func aDeletedServerFallsBackLikeNoRecord() {
        let store = defaults()
        LastProfile.record(remote, defaults: store)
        #expect(LastProfile.pick(from: [home], defaults: store) == home)
    }
}
