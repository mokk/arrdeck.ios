import ArrdeckAPI
import ArrdeckData
import Testing

@Suite struct CadenceTests {
    func torrent(_ state: String, dl: Int = 0) -> Torrent {
        .init(client: .qbittorrent, dl_speed: dl, id: "x", name: "n", progress: 0.5, size: 1, state: state, ul_speed: 0)
    }

    func summary(dl: Int, active: [Torrent]) -> TorrentSummary {
        .init(active: active, active_count: active.count, count: 10, totals: .init(dl_speed: dl, ul_speed: 0))
    }

    @Test func seedingOnlyIsIdle() {
        let blocks: [TorrentClient: Block<TorrentSummary>] = [
            .qbittorrent: .healthy(summary(dl: 0, active: [torrent("seeding")])),
        ]
        #expect(!Motion.summaryMoving(blocks))
    }

    @Test func downloadSpeedOrMovingStateIsFast() {
        #expect(Motion.summaryMoving([.qbittorrent: .healthy(summary(dl: 1, active: []))]))
        #expect(Motion.summaryMoving([.transmission: .healthy(summary(dl: 0, active: [torrent("checking")]))]))
        // stale data still counts: the bars it drew are still on screen
        #expect(Motion.summaryMoving([.qbittorrent: .stale(summary(dl: 0, active: [torrent("downloading")]), age: 30)]))
        #expect(!Motion.summaryMoving([.qbittorrent: .offline("down")]))
    }

    @Test func queueMovesWhileBytesRemain() {
        let done = QueueItem(app: .radarr, id: 1, size: 10, size_left: 0, status: "completed", title: "a")
        let going = QueueItem(app: .sonarr, id: 2, size: 10, size_left: 3, status: "downloading", title: "b")
        #expect(!Motion.queueMoving([.radarr: .healthy([done]), .sonarr: .healthy([])]))
        #expect(Motion.queueMoving([.radarr: .healthy([done]), .sonarr: .healthy([going])]))
    }

    @Test func onlyPlayingSessionsMove() {
        let paused = PlaySession(state: "paused", title: "a")
        let playing = PlaySession(state: "playing", title: "b")
        #expect(!Motion.sessionsMoving(.healthy([paused])))
        #expect(Motion.sessionsMoving(.healthy([paused, playing])))
        #expect(!Motion.sessionsMoving(.offline("plex down")))
    }

    @Test func scalingShrinksEveryInterval() {
        let fast = Cadence.scaled(by: 0.01)
        #expect(fast.fast == 0.05)
        #expect(fast.slow == 3)
        #expect(Cadence.standard.slow == 300)
    }
}
