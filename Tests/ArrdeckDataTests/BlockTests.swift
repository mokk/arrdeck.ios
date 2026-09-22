import ArrdeckAPI
import ArrdeckData
import Testing

@Suite struct BlockTests {
    @Test func okWithDataIsHealthy() {
        let block = Block(ok: true, data: [1, 2], error: nil, staleAgeSeconds: nil)
        #expect(block == .healthy([1, 2]))
        #expect(block.value == [1, 2])
        #expect(block.staleAge == nil)
    }

    @Test func notOkWithDataIsStaleWithAge() {
        let block = Block(ok: false, data: [1], error: "connect timeout", staleAgeSeconds: 120)
        #expect(block == .stale([1], age: 120))
        #expect(block.value == [1])
        #expect(block.staleAge == 120)
    }

    @Test func noDataIsOfflineWithReason() {
        let block = Block<[Int]>(ok: false, data: nil, error: "connect timeout", staleAgeSeconds: nil)
        #expect(block == .offline("connect timeout"))
        #expect(block.value == nil)
    }

    /// The wire struct the generator emits maps through the shape protocol —
    /// the conformance is what fails to compile if `data` ever disappears again.
    @Test func generatedServiceBlockConverts() {
        let wire = Components.Schemas.ServiceBlock_list_DiskSpaceOut__(
            data: [.init(free_bytes: 10, label: "radarr", path: "/data", total_bytes: 100)],
            error: "radarr: 502", ok: false, stale_age_seconds: 45
        )
        let block = Block(wire)
        #expect(block.staleAge == 45)
        #expect(block.value?.first?.path == "/data")
    }

    @Test func sliceKeepsTheOuterLifecycle() {
        let loading: Loadable<[ArrApp: Block<[Int]>]> = .loading
        #expect(loading.slice(ArrApp.radarr) == Loadable<Block<[Int]>>.loading)
        let failed: Loadable<[ArrApp: Block<[Int]>]> = .failed("down")
        #expect(failed.slice(ArrApp.radarr) == .failed("down"))
        let loaded: Loadable<[ArrApp: Block<[Int]>]> = .loaded([.radarr: .healthy([1])])
        #expect(loaded.slice(ArrApp.radarr) == .loaded(.healthy([1])))
        #expect(loaded.slice(ArrApp.sonarr) == .failed("missing sonarr"))
    }
}
