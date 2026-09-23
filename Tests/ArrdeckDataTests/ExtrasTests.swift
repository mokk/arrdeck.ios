import ArrdeckAPI
import ArrdeckData
import Foundation
import Testing

actor FakeExtrasAPI: ExtrasAPI {
    var failure: APIError?
    private(set) var calls: [String] = []
    func set(failure: APIError?) { self.failure = failure }
    func count(_ c: String) -> Int { calls.filter { $0 == c }.count }
    private func log(_ c: String) throws {
        calls.append(c)
        if let failure { throw failure }
    }

    func releases(_ target: ReleaseTarget) async throws -> [ArrRelease] {
        try log("releases-\(target)")
        return [.init(approved: true, guid: "g1", indexer_id: 3, title: "good"),
                .init(approved: false, guid: "g2", indexer_id: 3, rejections: ["too small"], title: "bad")]
    }
    func grabArrRelease(_ app: ArrApp, guid: String, indexerID: Int) async throws { try log("grab-\(app.rawValue)-\(guid)-\(indexerID)") }
    func renamePreview(_ ref: MediaRef) async throws -> [RenamePreview] {
        try log("preview-\(ref.id)")
        return [.init(existing_path: "a", file_id: 1, new_path: "b"), .init(existing_path: "c", file_id: 2, new_path: "d")]
    }
    func renameFiles(_ ref: MediaRef, fileIDs: [Int]) async throws { try log("rename-\(ref.id)-\(fileIDs.map(String.init).joined(separator: ","))") }
    func addTorrent(_ client: TorrentClient, url: String, category: String, paused: Bool) async throws {
        try log("add-\(client.rawValue)-\(url)-\(category)-\(paused)")
    }
    func qbitCategories() async throws -> [String] { try log("categories"); return ["movies", "tv"] }
    func qbitTags() async throws -> [String] { try log("tags"); return ["keep", "temp"] }
    func setLimits(_ client: TorrentClient, id: String, downloadKiB: Int, uploadKiB: Int) async throws { try log("limits-\(id)-\(downloadKiB)-\(uploadKiB)") }
    func setPriority(_ client: TorrentClient, ids: [String], position: QueuePosition) async throws { try log("priority-\(position.rawValue)") }
    func forceStart(ids: [String]) async throws { try log("force-\(ids.joined())") }
    func setTags(ids: [String], tags: [String], remove: Bool) async throws { try log("tag-\(tags.joined())-\(remove)") }
    func setCategory(id: String, category: String) async throws { try log("category-\(category)") }
    func bulkEdit(_ app: ArrApp, ids: [Int], monitored: Bool?, qualityProfile: Int?, tags: [Int]?, tagChange: TagChange?) async throws {
        try log("bulk-\(app.rawValue)-\(ids.map(String.init).joined(separator: ","))-\(monitored.map(String.init) ?? "_")-\(qualityProfile.map(String.init) ?? "_")-\(tagChange?.rawValue ?? "_")")
    }
    func bulkDelete(_ app: ArrApp, ids: [Int], deleteFiles: Bool) async throws { try log("bulkdelete-\(ids.count)-\(deleteFiles)") }
    func bulkSearch(_ app: ArrApp, ids: [Int]) async throws { try log("bulksearch-\(ids.count)") }
}

@MainActor
@Suite struct ExtrasModelTests {
    @Test func releaseTargetsPickTheApp() {
        #expect(ReleaseTarget.movie(1).app == .radarr)
        #expect(ReleaseTarget.season(series: 1, season: 2).app == .sonarr)
        #expect(ReleaseTarget.episode(series: 1, episode: 9).app == .sonarr)
    }

    @Test func releasesLoadAndGrab() async {
        let api = FakeExtrasAPI()
        let model = ReleasesModel(target: .movie(180), api: api, onSessionLost: {})
        await model.load()
        #expect(model.releases.value?.count == 2)
        await model.grab(model.releases.value![0])
        #expect(await api.count("grab-radarr-g1-3") == 1)
        #expect(model.grabbed.contains("g1"))
        await api.set(failure: .unexpectedStatus(500))
        await model.grab(model.releases.value![1])
        #expect(model.actionError == "HTTP 500")
        #expect(!model.grabbed.contains("g2"))
    }

    @Test func renameCardShowsThenClears() async {
        let api = FakeExtrasAPI()
        let model = RenameModel(ref: .movie(180), api: api, onSessionLost: {})
        await model.load()
        #expect(model.previews.count == 2)
        await model.renameAll()
        #expect(await api.count("rename-180-1,2") == 1)
        #expect(model.started)
        #expect(model.previews.isEmpty, "the card disappears once the rename is queued")
    }

    @Test func addTorrentNeedsAUrlAndLoadsQbitCategories() async {
        let api = FakeExtrasAPI()
        let model = AddTorrentModel(clients: [.qbittorrent, .transmission], api: api, onSessionLost: {})
        #expect(!model.canSubmit)
        await model.loadCategories()
        #expect(model.categories == ["movies", "tv"])
        model.url = " magnet:?xt=urn:btih:abc "
        model.category = "movies"
        model.paused = true
        #expect(model.canSubmit)
        await model.add()
        #expect(await api.count("add-qbittorrent-magnet:?xt=urn:btih:abc-movies-true") == 1)
        #expect(model.done)

        model.client = .transmission
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.categories.isEmpty, "Transmission has no categories")
    }

    @Test func torrentExtrasTrackLimitsCategoryAndTags() async {
        let api = FakeExtrasAPI()
        let torrent = Torrent(client: .qbittorrent, dl_speed: 0, id: "h1", name: "n", progress: 1, size: 1, state: "seeding", tags: ["keep"], ul_speed: 0)
        let model = TorrentExtrasModel(torrent: torrent, api: api, onSessionLost: {})
        model.apply(.init(categories: ["movies", "tv"], category: "movies", dl_limit_kib: 100, files: [], ul_limit_kib: 0))
        #expect(model.downloadKiB == "100")
        #expect(!model.limitsDirty)
        model.downloadKiB = "250"
        #expect(model.limitsDirty)
        await model.saveLimits()
        #expect(await api.count("limits-h1-250-0") == 1)
        #expect(!model.limitsDirty)

        await model.loadTags()
        #expect(model.allTags == ["keep", "temp"])
        await model.toggle(tag: "keep")
        #expect(await api.count("tag-keep-true") == 1, "a tag the torrent has is removed")
        #expect(!model.tags.contains("keep"))
        await model.toggle(tag: "temp")
        #expect(model.tags.contains("temp"))
        await model.setCategory("tv")
        #expect(model.category == "tv")
        await model.move(.top)
        #expect(await api.count("priority-top") == 1)
        await model.forceStart()
        #expect(await api.count("force-h1") == 1)
    }
}
