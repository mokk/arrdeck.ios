import Foundation
import Testing
@testable import ArrdeckKit

struct ProfileStoreTests {
    @Test func profilesRoundTripThroughAStore() throws {
        let store = InMemoryProfileStore()
        let profile = ServerProfile(
            baseURL: URL(string: "http://10.0.0.154:3500")!,
            name: "Home",
            lastKnown: BackendInfo(version: "0.2.0", features: ["diagnose"])
        )
        try store.save([profile])
        #expect(try store.load() == [profile])
    }

    @Test func emptyStoreLoadsAsNoProfilesNotAnError() throws {
        #expect(try InMemoryProfileStore().load() == [])
    }

    @Test func cachedCapabilitiesSurviveTheRoundTrip() throws {
        // lastKnown is what lets the UI gate features while offline, so losing
        // it in storage would flash the whole UI on and off with connectivity.
        let store = InMemoryProfileStore()
        var profile = ServerProfile(
            baseURL: URL(string: "https://deck.example.com")!, name: "Remote"
        )
        profile.lastKnown = .legacy
        try store.save([profile])
        #expect(try store.load().first?.lastKnown == .legacy)
    }

    @Test func profilesSavedBeforeTheHomeAddressStillDecode() throws {
        // what the Keychain holds from builds without homeURL: losing it would
        // look like every saved server vanished after an update
        let saved = Data("""
        [{"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "baseURL": "https://deck.example.com",
          "name": "Remote", "lastKnown": {"version": "0.2.0", "features": ["calendar"]}}]
        """.utf8)
        let profiles = try JSONDecoder().decode([ServerProfile].self, from: saved)
        let profile = try #require(profiles.first)
        #expect(profile.baseURL == URL(string: "https://deck.example.com")!)
        #expect(profile.name == "Remote")
        #expect(profile.lastKnown?.supports(.calendar) == true)
        #expect(profile.homeURL == nil)
    }

    @Test func theHomeAddressSurvivesTheRoundTrip() throws {
        let store = InMemoryProfileStore()
        var profile = ServerProfile(baseURL: URL(string: "https://deck.example.com")!, name: "Remote")
        profile.homeURL = URL(string: "http://10.0.0.154:3500")!
        try store.save([profile])
        let encoded = try JSONEncoder().encode([profile])
        #expect(try JSONDecoder().decode([ServerProfile].self, from: encoded) == [profile])
        #expect(try store.load().first?.homeURL == URL(string: "http://10.0.0.154:3500")!)
    }
}
