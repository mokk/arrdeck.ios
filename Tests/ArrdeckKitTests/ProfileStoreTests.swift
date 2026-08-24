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
}
