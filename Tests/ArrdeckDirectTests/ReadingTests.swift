import ArrdeckData
import Foundation
import Testing
@testable import ArrdeckDirect

@Suite struct ReadingStoreTests {
    @Test func markingReadStampsWhenAndKeepsThatDateUntilItIsUnread() {
        var map = DirectBackend.apply([:], 7, .reading, now: 100)
        #expect(map[7]?.readingStatus == .reading && map[7]?.finished_at == nil && map[7]?.updated_at == 100)
        map = DirectBackend.apply(map, 7, .read, now: 200)
        #expect(map[7]?.finished_at == 200)
        // read again, later: the first finish stands
        map = DirectBackend.apply(map, 7, .read, now: 300)
        #expect(map[7]?.finished_at == 200 && map[7]?.updated_at == 300)
        map = DirectBackend.apply(map, 7, .toRead, now: 400)
        #expect(map[7]?.finished_at == nil)
        #expect(DirectBackend.apply(map, 7, nil, now: 500)[7] == nil)
    }

    @Test func statusesStayInTheStoreTheBackendWasGiven() async throws {
        let store = InMemoryReadingStore()
        let api = DirectBackend(registry: Registry(store: InMemoryConnectionStore()), reading: store)
        _ = try await api.setReading(3, .reading)
        _ = try await api.setReading(4, .toRead)
        #expect(store.load().keys.sorted() == [3, 4])
        let again = DirectBackend(registry: Registry(store: InMemoryConnectionStore()), reading: store)
        #expect(try await again.reading()[3]?.readingStatus == .reading)
    }

    @Test func aProfilesStatusesSurviveInTheDefaultsAndGoWithIt() {
        let id = UUID()
        defer { DefaultsReadingStore.delete(profileID: id) }
        let store = DefaultsReadingStore(profileID: id)
        store.save([9: Reading(finished_at: 50, status: .read, updated_at: 50)])
        #expect(DefaultsReadingStore(profileID: id).load()[9]?.finished_at == 50)
        #expect(DefaultsReadingStore(profileID: UUID()).load().isEmpty, "another profile's are its own")
        DefaultsReadingStore.delete(profileID: id)
        #expect(DefaultsReadingStore(profileID: id).load().isEmpty)
    }
}
