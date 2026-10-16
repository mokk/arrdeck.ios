import Foundation
import Testing
@testable import ArrdeckKit

struct ProfileStoreTests {
    @Test func profilesRoundTripThroughAStore() throws {
        let store = InMemoryProfileStore()
        let profile = ServerProfile(name: "Home")
        try store.save([profile])
        #expect(try store.load() == [profile])
    }

    @Test func emptyStoreLoadsAsNoProfilesNotAnError() throws {
        #expect(try InMemoryProfileStore().load() == [])
    }

    @Test func whatThisBuildSavesItReadsBack() throws {
        let profiles = [ServerProfile(name: "Home"), ServerProfile(name: "Cabin")]
        #expect(try KeychainProfileStore.decode(JSONEncoder().encode(profiles)) == profiles)
    }

    @Test func anOlderBuildsDirectProfileKeepsItsIDSoItsServicesStay() throws {
        // the connections are kept in the Keychain under the profile's id
        let saved = Data("""
        [{"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF",
          "baseURL": "arrdeck-direct:6F9619FF-8B86-D011-B42D-00C04FC964FF", "name": "Home"}]
        """.utf8)
        let profiles = try KeychainProfileStore.decode(saved)
        #expect(profiles == [ServerProfile(id: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!, name: "Home")])
    }

    @Test func anOlderBuildsServerProfileIsLeftOut() throws {
        // an arrdeck server the app no longer talks to: it would open on nothing
        let saved = Data("""
        [{"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "baseURL": "https://deck.example.com",
          "name": "Remote", "lastKnown": {"version": "0.2.0", "features": ["calendar"]},
          "homeURL": "http://10.0.0.154:3500"},
         {"id": "7F9619FF-8B86-D011-B42D-00C04FC964FF",
          "baseURL": "arrdeck-direct:7F9619FF-8B86-D011-B42D-00C04FC964FF", "name": "Home"}]
        """.utf8)
        #expect(try KeychainProfileStore.decode(saved).map(\.name) == ["Home"])
    }
}
