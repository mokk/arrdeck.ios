import ArrdeckData
import Foundation
import Testing
@testable import ArrdeckDirect

private let qbitConnection = ServiceConnection(url: "http://10.0.0.5:8080")
private let transmissionConnection = ServiceConnection(url: "http://10.0.0.5:9091")

private func ok(_ json: String) -> ServiceResponse {
    ServiceResponse(status: 200, headers: [:], data: Data(json.utf8))
}

private func body(_ request: URLRequest) -> String {
    String(decoding: request.httpBody ?? Data(), as: UTF8.self)
}

private func rpcBody(_ request: URLRequest) throws -> JSON {
    try JSON(data: request.httpBody ?? Data())
}

extension StubTransport {
    /// Transmission has one endpoint; answers by the RPC method asked for.
    func transmission(_ answers: [String: String]) {
        on("POST /transmission/rpc") { request in
            let method = try rpcBody(request)["method"].string ?? ""
            guard let arguments = answers[method] else {
                return ok(#"{"result": "method name not recognized", "arguments": {}}"#)
            }
            return ok(#"{"result": "success", "arguments": \#(arguments)}"#)
        }
    }

    func posts(_ suffix: String) -> [URLRequest] {
        requests.filter { $0.httpMethod == "POST" && ($0.url?.path() ?? "").hasSuffix(suffix) }
    }
}

// qBittorrent's /torrents/info, trimmed to the fields the list reads
private let qbitTorrents = """
[
  {"hash": "aaaa1111", "name": "Dune.Part.Two.2024.2160p", "state": "stalledDL", "progress": 0.42,
   "size": 21474836480, "dlspeed": 0, "upspeed": 0, "eta": 8640000, "ratio": 0.0, "uploaded": 0,
   "added_on": 1714000300, "completion_on": 0, "tracker": "https://tracker.torrentleech.org/a/announce",
   "tags": "4k, movies"},
  {"hash": "bbbb2222", "name": "Shogun.S01E01.1080p", "state": "pausedUP", "progress": 1,
   "size": 3221225472, "dlspeed": 0, "upspeed": 0, "eta": 8640000, "ratio": 1.52, "uploaded": 4896262144,
   "added_on": 1714000100, "completion_on": 1714003600, "tracker": "udp://open.stealth.si:80/announce",
   "tags": ""},
  {"hash": "cccc3333", "name": "Some.Linux.ISO", "state": "uploading", "progress": 1,
   "size": 1073741824, "dlspeed": 0, "upspeed": 51200, "eta": 120, "ratio": 3.1, "uploaded": 3328599654,
   "added_on": 1714000200, "completion_on": 1714001000, "tracker": "https://www.iptorrents.com/announce",
   "tags": ""},
  {"hash": "dddd4444", "name": "Mystery", "state": "brandNewState", "progress": 0, "size": 1,
   "dlspeed": 0, "upspeed": 0, "eta": 0, "added_on": 1714000000, "tracker": ""}
]
"""

// Transmission's torrent-get with the server's field list
private let transmissionTorrents = """
{"torrents": [
  {"id": 7, "hashString": "eeee5555", "name": "The.Bear.S03.1080p", "status": 6, "percentDone": 1,
   "totalSize": 9663676416, "rateDownload": 0, "rateUpload": 10240, "eta": -1, "uploadRatio": 0.8,
   "uploadedEver": 7730941132, "errorString": "", "addedDate": 1714000250, "doneDate": 1714002000,
   "trackers": [{"announce": "https://tracker.iptorrents.com/announce"}]},
  {"id": 8, "hashString": "ffff6666", "name": "Broken.Torrent", "status": 4, "percentDone": 0.1,
   "totalSize": 1000, "rateDownload": 2048, "rateUpload": 0, "eta": 300, "uploadRatio": -1,
   "uploadedEver": 0, "errorString": "Tracker gave HTTP response code 404 (Not Found)",
   "addedDate": 1714000050, "doneDate": 0, "trackers": []}
]}
"""

private func torrentStack() -> (DirectBackend, StubTransport) {
    let (direct, transport) = backend([
        "qbittorrent": qbitConnection, "transmission": transmissionConnection,
        "prowlarr": .arr("http://10.0.0.5:9696"), "radarr": .arr("http://10.0.0.5:7878"),
    ])
    transport.on("GET /api/v2/torrents/info", json: qbitTorrents)
    transport.on("GET /api/v2/transfer/info", json: #"{"dl_info_speed": 1048576, "up_info_speed": 51200}"#)
    transport.transmission([
        "torrent-get": transmissionTorrents,
        "session-stats": #"{"downloadSpeed": 2048, "uploadSpeed": 10240}"#,
    ])
    transport.on("GET /api/v1/indexer", json: """
    [{"name": "IPTorrents", "indexerUrls": ["https://iptorrents.com/"], "legacyUrls": ["https://www.iptorrents.me/"]}]
    """)
    transport.on("GET /api/v3/history", json: """
    {"records": [{"downloadId": "AAAA1111", "data": {"indexer": "TorrentLeech (Prowlarr)"}},
                 {"downloadId": "", "data": {"indexer": "Nothing"}}]}
    """)
    return (direct, transport)
}

struct TorrentListTests {
    @Test func bothClientsAreMappedIntoTheServersStates() async throws {
        let (direct, _) = torrentStack()
        let groups = try await direct.torrents(TorrentQuery())
        let qbit = try #require(groups[.qbittorrent]?.value)
        let byName = Dictionary(uniqueKeysWithValues: qbit.torrents.map { ($0.name, $0) })

        let dune = try #require(byName["Dune.Part.Two.2024.2160p"])
        #expect(dune.state == "stalled")
        #expect(dune.eta == nil) // qBittorrent's 100 days means no estimate
        #expect(dune.completed_on == nil)
        #expect(dune.tags == ["4k", "movies"])
        #expect(dune.id == "aaaa1111")
        #expect(dune.client == .qbittorrent)

        let shogun = try #require(byName["Shogun.S01E01.1080p"])
        #expect(shogun.state == "completed") // paused after finishing
        #expect(shogun.completed_on == 1_714_003_600)
        #expect(shogun.tags == [])
        #expect(shogun.uploaded == 4_896_262_144)

        #expect(byName["Some.Linux.ISO"]?.state == "seeding")
        #expect(byName["Some.Linux.ISO"]?.eta == 120)
        // a state the map does not know passes through as qBittorrent named it
        #expect(byName["Mystery"]?.state == "brandNewState")

        let tm = try #require(groups[.transmission]?.value)
        let bear = try #require(tm.torrents.first { $0.id == "7" })
        #expect(bear.state == "seeding")
        #expect(bear.eta == nil)
        #expect(bear.tags == [])
        #expect(bear.error == nil)
        let broken = try #require(tm.torrents.first { $0.id == "8" })
        #expect(broken.state == "error") // an error string wins over the status
        #expect(broken.error == "Tracker gave HTTP response code 404 (Not Found)")
        #expect(broken.eta == 300)
        #expect(broken.completed_on == nil)
    }

    @Test func eachClientCarriesItsTotalsStatesAndUncappedCount() async throws {
        let (direct, _) = torrentStack()
        let groups = try await direct.torrents(TorrentQuery(limit: 2))
        let qbit = try #require(groups[.qbittorrent]?.value)
        // newest first, capped, with the real count beside it
        #expect(qbit.torrents.map(\.id) == ["aaaa1111", "cccc3333"])
        #expect(qbit.total == 4)
        #expect(qbit.states == ["brandNewState", "completed", "seeding", "stalled"])
        #expect(qbit.totals.dl_speed == 1_048_576)
        #expect(qbit.totals.ul_speed == 51200)
        let tm = try #require(groups[.transmission]?.value)
        #expect(tm.totals.dl_speed == 2048)
        #expect(tm.total == 2)
    }

    @Test func filtersApplyBeforeTheCapButTheStatesListStaysWhole() async throws {
        let (direct, _) = torrentStack()
        let seeding = try await direct.torrents(TorrentQuery(state: "seeding"))
        #expect(seeding[.qbittorrent]?.value?.torrents.map(\.name) == ["Some.Linux.ISO"])
        #expect(seeding[.qbittorrent]?.value?.states?.count == 4)
        #expect(seeding[.transmission]?.value?.torrents.map(\.id) == ["7"])

        let named = try await direct.torrents(TorrentQuery(text: "  shogun ", state: "all", sort: .name, descending: false))
        #expect(named[.qbittorrent]?.value?.torrents.map(\.name) == ["Shogun.S01E01.1080p"])
        #expect(named[.transmission]?.value?.total == 0)
    }

    @Test func trackersAreNamedByGrabThenDomainThenHost() async throws {
        let (direct, _) = torrentStack()
        let groups = try await direct.torrents(TorrentQuery())
        let all = (groups[.qbittorrent]?.value?.torrents ?? []) + (groups[.transmission]?.value?.torrents ?? [])
        let tracker = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0.tracker) })
        // the grab history knows this hash, under Prowlarr's suffix
        #expect(tracker["aaaa1111"] == "TorrentLeech")
        // www. and tracker. are dropped, and the domain is one of Prowlarr's indexers
        #expect(tracker["cccc3333"] == "IPTorrents")
        #expect(tracker["7"] == "IPTorrents")
        // nobody knows this one: the bare host
        #expect(tracker["bbbb2222"] == "open.stealth.si")
        #expect(tracker["dddd4444"] == .some(nil))
        #expect(tracker["8"] == .some(nil))
    }

    @Test func aDomainLearnedFromAGrabNamesItsOtherTorrents() async throws {
        let (direct, transport) = torrentStack()
        transport.on("GET /api/v2/torrents/info", json: """
        [{"hash": "aaaa1111", "name": "a", "state": "uploading", "tracker": "https://tracker.torrentleech.org/x"},
         {"hash": "9999", "name": "b", "state": "uploading", "tracker": "https://tracker.torrentleech.org/y"}]
        """)
        let groups = try await direct.torrents(TorrentQuery())
        #expect(groups[.qbittorrent]?.value?.torrents.map(\.tracker) == ["TorrentLeech", "TorrentLeech"])
        let learned: [String: String]? = direct.cache.stale("tracker:learned_domains")?.value
        #expect(learned == ["torrentleech.org": "TorrentLeech"])
    }

    @Test func aMissingClientIsOfflineAndTheOtherStillLists() async throws {
        let (direct, transport) = backend(["transmission": transmissionConnection])
        transport.transmission(["torrent-get": transmissionTorrents, "session-stats": "{}"])
        let groups = try await direct.torrents(TorrentQuery())
        #expect(groups[.qbittorrent] == .offline("not configured"))
        #expect(groups[.transmission]?.value?.torrents.count == 2)
        // no Prowlarr, no arrs: the hosts as they are
        #expect(groups[.transmission]?.value?.torrents.first?.tracker == "iptorrents.com")
    }

    @Test func transmissionIsAskedForTheServersFields() async throws {
        let (direct, transport) = torrentStack()
        _ = try await direct.torrents(TorrentQuery())
        let get = try #require(try transport.posts("/transmission/rpc").first { try rpcBody($0)["method"] == "torrent-get" })
        let fields = try rpcBody(get)["arguments"]["fields"].array.compactMap(\.string)
        #expect(fields.count == 17)
        #expect(fields.contains("hashString") && fields.contains("trackers") && fields.contains("errorString"))
    }
}

struct TorrentActionTests {
    @Test func qbittorrentPauseFallsBackToTheOldNameOnlyWhenRefused() async throws {
        let (direct, transport) = backend(["qbittorrent": qbitConnection])
        transport.on("POST /api/v2/torrents/stop", status: 404, json: "")
        transport.on("POST /api/v2/torrents/pause", json: "")
        try await direct.pause(.qbittorrent, ids: ["aaaa", "bbbb"])
        #expect(body(try #require(transport.posts("/torrents/pause").first)) == "hashes=aaaa%7Cbbbb")

        // a client that is down is not asked again under the other name
        let (down, downTransport) = backend(["qbittorrent": qbitConnection])
        downTransport.on("POST /api/v2/torrents/start", status: 502, json: "")
        downTransport.on("POST /api/v2/torrents/resume", json: "")
        await #expect(throws: APIError.refused("upstream HTTP 502")) {
            try await down.resume(.qbittorrent, ids: ["aaaa"])
        }
        #expect(downTransport.posts("/torrents/resume").isEmpty)
    }

    @Test func deletingSaysWhetherTheDataGoesToo() async throws {
        let (direct, transport) = backend(["qbittorrent": qbitConnection, "transmission": transmissionConnection])
        transport.on("POST /api/v2/torrents/delete", json: "")
        transport.transmission(["torrent-remove": "{}"])
        try await direct.delete(.qbittorrent, ids: ["aaaa"], deleteData: true)
        #expect(body(try #require(transport.posts("/torrents/delete").first)) == "deleteFiles=true&hashes=aaaa")
        try await direct.delete(.transmission, ids: ["7", "8"], deleteData: false)
        let arguments = try rpcBody(try #require(transport.posts("/transmission/rpc").last))["arguments"]
        #expect(arguments == ["ids": [7, 8], "delete-local-data": false])
    }

    @Test func transmissionIDsMustBeNumbers() async throws {
        let (direct, transport) = backend(["transmission": transmissionConnection])
        await #expect(throws: APIError.refused("transmission ids must be integers")) {
            try await direct.recheck(.transmission, ids: ["abc"])
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func throttlingQbittorrentOnlyTogglesWhenItDiffers() async throws {
        let (direct, transport) = backend(["qbittorrent": qbitConnection, "transmission": transmissionConnection])
        transport.on("GET /api/v2/transfer/speedLimitsMode", json: "1")
        transport.on("POST /api/v2/transfer/toggleSpeedLimitsMode", json: "")
        transport.transmission(["session-get": #"{"alt-speed-enabled": false}"#, "session-set": "{}"])

        #expect(try await direct.speedLimit() == [.qbittorrent: true, .transmission: false])
        try await direct.setSpeedLimit(.qbittorrent, enabled: true)
        #expect(transport.posts("/toggleSpeedLimitsMode").isEmpty)
        try await direct.setSpeedLimit(.qbittorrent, enabled: false)
        #expect(transport.posts("/toggleSpeedLimitsMode").count == 1)

        try await direct.setSpeedLimit(.transmission, enabled: true)
        let set = try rpcBody(try #require(transport.posts("/transmission/rpc").last))
        #expect(set == ["method": "session-set", "arguments": ["alt-speed-enabled": true]])
    }

    @Test func aMissingClientReadsAsNotThrottled() async throws {
        let (direct, _) = backend([:])
        #expect(try await direct.speedLimit() == [.qbittorrent: false, .transmission: false])
    }

    @Test func removingFromTheQueueTakesItOutOfTheClientWithoutBlocklisting() async throws {
        let (direct, transport) = backend(["sonarr": .arr()])
        transport.on("DELETE /api/v3/queue/42", json: "")
        try await direct.removeFromQueue(app: .sonarr, id: 42)
        #expect(transport.requests.first?.url?.query() == "blocklist=false&removeFromClient=true")
    }
}

struct TorrentDetailsTests {
    @Test func qbittorrentDetailsInKiBWithoutThePseudoTrackers() async throws {
        let (direct, transport) = backend(["qbittorrent": qbitConnection])
        transport.on("GET /api/v2/torrents/files", json: """
        [{"index": 0, "name": "Dune/Dune.mkv", "size": 21000000000, "progress": 0.5, "priority": 1},
         {"index": 1, "name": "Dune/sample.mkv", "size": 50000000, "progress": 0, "priority": 0}]
        """)
        transport.on("GET /api/v2/torrents/info", json: #"[{"hash": "aaaa", "dl_limit": 2097152, "up_limit": -1, "category": "radarr"}]"#)
        transport.on("GET /api/v2/torrents/categories", json: #"{"tv-sonarr": {"name": "tv-sonarr"}, "radarr": {"name": "radarr"}}"#)
        transport.on("GET /api/v2/torrents/trackers", json: """
        [{"url": "** [DHT] **", "status": 2, "msg": ""},
         {"url": "https://tracker.torrentleech.org/a/announce", "status": 4, "msg": "unregistered torrent"},
         {"url": "udp://open.stealth.si:80/announce", "status": 2, "msg": ""}]
        """)
        let details = try await direct.details(.qbittorrent, id: "aaaa")
        #expect(details.dl_limit_kib == 2048)
        #expect(details.ul_limit_kib == 0) // -1 is qBittorrent's "none"
        #expect(details.category == "radarr")
        #expect(details.categories == ["radarr", "tv-sonarr"])
        #expect(details.files.map(\.wanted) == [true, false])
        #expect(details.files.map(\.index) == [0, 1])
        #expect(details.trackers == [
            Tracker(host: "https://tracker.torrentleech.org/a/announce", message: "unregistered torrent", ok: false),
            Tracker(host: "udp://open.stealth.si:80/announce", message: nil, ok: true),
        ])
        #expect(transport.requests.contains { $0.url?.query() == "hashes=aaaa" })
    }

    @Test func transmissionDetailsCountLimitsOnlyWhenTheyApply() async throws {
        let (direct, transport) = backend(["transmission": transmissionConnection])
        transport.transmission(["torrent-get": """
        {"torrents": [{
          "files": [{"name": "Bear/E01.mkv", "length": 2000, "bytesCompleted": 500},
                    {"name": "Bear/E02.mkv", "length": 0, "bytesCompleted": 0}],
          "fileStats": [{"wanted": true}, {"wanted": false}],
          "downloadLimit": 500, "downloadLimited": true, "uploadLimit": 100, "uploadLimited": false,
          "trackerStats": [{"host": "tracker.example.org", "announce": "https://tracker.example.org/announce",
                            "lastAnnounceSucceeded": false, "lastAnnounceResult": "Connection failed"}]
        }]}
        """])
        let details = try await direct.details(.transmission, id: "7")
        #expect(details.dl_limit_kib == 500)
        #expect(details.ul_limit_kib == 0)
        #expect(details.files.map(\.progress) == [0.25, 0])
        #expect(details.files.map(\.wanted) == [true, false])
        #expect(details.categories == [])
        #expect(details.category == nil)
        #expect(details.trackers == [Tracker(host: "tracker.example.org", message: "Connection failed", ok: false)])
        let ids = try rpcBody(try #require(transport.requests.first))["arguments"]["ids"]
        #expect(ids == [7])
    }
}

struct TorrentExtrasTests {
    @Test func limitsGoToQbittorrentInBytesAndToTransmissionInKiB() async throws {
        let (direct, transport) = backend(["qbittorrent": qbitConnection, "transmission": transmissionConnection])
        transport.on("POST /api/v2/torrents/setDownloadLimit", json: "")
        transport.on("POST /api/v2/torrents/setUploadLimit", json: "")
        transport.transmission(["torrent-set": "{}"])
        try await direct.setLimits(.qbittorrent, id: "aaaa", downloadKiB: 1024, uploadKiB: 0)
        #expect(body(try #require(transport.posts("/setDownloadLimit").first)) == "hashes=aaaa&limit=1048576")
        #expect(body(try #require(transport.posts("/setUploadLimit").first)) == "hashes=aaaa&limit=0")

        try await direct.setLimits(.transmission, id: "7", downloadKiB: 0, uploadKiB: 50)
        let arguments = try rpcBody(try #require(transport.posts("/transmission/rpc").last))["arguments"]
        #expect(arguments == [
            "ids": [7], "downloadLimit": 0, "downloadLimited": false, "uploadLimit": 50, "uploadLimited": true,
        ])
    }

    @Test func queuePositionsUseEachClientsNames() async throws {
        let (direct, transport) = backend(["qbittorrent": qbitConnection, "transmission": transmissionConnection])
        transport.on("POST /api/v2/torrents/increasePrio", json: "")
        transport.on("POST /api/v2/torrents/bottomPrio", json: "")
        transport.transmission(["queue-move-top": "{}"])
        try await direct.setPriority(.qbittorrent, ids: ["a", "b"], position: .up)
        try await direct.setPriority(.qbittorrent, ids: ["a"], position: .bottom)
        #expect(body(try #require(transport.posts("/increasePrio").first)) == "hashes=a%7Cb")
        #expect(transport.posts("/bottomPrio").count == 1)
        try await direct.setPriority(.transmission, ids: ["7"], position: .top)
        #expect(try rpcBody(try #require(transport.posts("/transmission/rpc").last))["method"] == "queue-move-top")
    }

    @Test func tagsCategoryAndForceStart() async throws {
        let (direct, transport) = backend(["qbittorrent": qbitConnection])
        for action in ["addTags", "removeTags", "setCategory", "setForceStart"] {
            transport.on("POST /api/v2/torrents/\(action)", json: "")
        }
        transport.on("GET /api/v2/torrents/tags", json: #"["4k", "keep"]"#)
        transport.on("GET /api/v2/torrents/categories", json: #"{"tv": {}, "movies": {}, "Books": {}}"#)
        try await direct.setTags(ids: ["a"], tags: ["4k", "keep"], remove: false)
        try await direct.setTags(ids: ["a"], tags: ["keep"], remove: true)
        try await direct.setCategory(id: "a", category: "")
        try await direct.forceStart(ids: ["a"])
        #expect(body(try #require(transport.posts("/addTags").first)) == "hashes=a&tags=4k%2Ckeep")
        #expect(body(try #require(transport.posts("/removeTags").first)) == "hashes=a&tags=keep")
        #expect(body(try #require(transport.posts("/setCategory").first)) == "category=&hashes=a")
        #expect(body(try #require(transport.posts("/setForceStart").first)) == "hashes=a&value=true")
        #expect(try await direct.qbitTags() == ["4k", "keep"])
        #expect(try await direct.qbitCategories() == ["Books", "movies", "tv"])
    }
}

struct AddTorrentTests {
    @Test func aFileGoesToQbittorrentAsTheServersMultipartUpload() async throws {
        let (direct, transport) = backend(["qbittorrent": qbitConnection])
        transport.on("POST /api/v2/torrents/add", json: "Ok.")
        let torrent = Data("d8:announce35:udp://tracker.example:80/announcee".utf8)
        try await direct.addTorrentFile(.qbittorrent, filename: "ubuntu.torrent", data: torrent, category: "linux", paused: true)

        let request = try #require(transport.posts("/torrents/add").first)
        let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))
        let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
        let expected = [
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"category\"\r\n\r\nlinux\r\n",
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"stopped\"\r\n\r\ntrue\r\n",
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"paused\"\r\n\r\ntrue\r\n",
            "--\(boundary)\r\nContent-Disposition: form-data; name=\"torrents\"; filename=\"ubuntu.torrent\"\r\n"
                + "Content-Type: application/x-bittorrent\r\n\r\n"
                + "d8:announce35:udp://tracker.example:80/announcee\r\n",
            "--\(boundary)--\r\n",
        ].joined()
        #expect(body(request) == expected)
        // the CSRF check wants these on every write, not just the login
        #expect(request.value(forHTTPHeaderField: "Referer") == "http://10.0.0.5:8080")
    }

    @Test func aFileWithNoNameOrCategoryIsStillAnUpload() async throws {
        let (direct, transport) = backend(["qbittorrent": qbitConnection])
        transport.on("POST /api/v2/torrents/add", json: "Ok.")
        try await direct.addTorrentFile(.qbittorrent, filename: "", data: Data([1, 2]), category: "", paused: false)
        let sent = body(try #require(transport.posts("/torrents/add").first))
        #expect(sent.contains("filename=\"upload.torrent\""))
        #expect(!sent.contains("name=\"category\""))
        #expect(!sent.contains("name=\"paused\""))
    }

    @Test func aFileGoesToTransmissionAsBase64() async throws {
        let (direct, transport) = backend(["transmission": transmissionConnection])
        transport.transmission(["torrent-add": #"{"torrent-added": {"id": 9}}"#])
        try await direct.addTorrentFile(.transmission, filename: "x.torrent", data: Data([0xDE, 0xAD]), category: "tv", paused: false)
        let sent = try rpcBody(try #require(transport.requests.last))
        #expect(sent == ["method": "torrent-add", "arguments": ["paused": false, "metainfo": "3q0="]])
    }

    @Test func aLinkGoesToQbittorrentAsAForm() async throws {
        let (direct, transport) = backend(["qbittorrent": qbitConnection])
        transport.on("POST /api/v2/torrents/add", json: "Ok.")
        try await direct.addTorrent(.qbittorrent, url: "magnet:?xt=urn:btih:abc", category: "", paused: false)
        #expect(body(try #require(transport.posts("/torrents/add").first)) == "urls=magnet%3A%3Fxt%3Durn%3Abtih%3Aabc")
    }

    @Test func refusalsAreWordedAsTheServerDid() async throws {
        let (direct, transport) = backend(["qbittorrent": qbitConnection, "transmission": transmissionConnection])
        transport.on("POST /api/v2/torrents/add", json: "Fails.")
        transport.transmission(["torrent-add": #"{"torrent-duplicate": {"id": 7}}"#])
        await #expect(throws: APIError.refused("qBittorrent rejected the torrent")) {
            try await direct.addTorrent(.qbittorrent, url: "https://example.org/x.torrent", category: "", paused: false)
        }
        await #expect(throws: APIError.refused("torrent already added")) {
            try await direct.addTorrent(.transmission, url: "magnet:?xt=urn:btih:abc", category: "", paused: true)
        }
    }
}

struct ReleaseTests {
    @Test func releasesAreMappedAndGrabbableOnesComeFirst() async throws {
        let (direct, transport) = backend(["sonarr": .arr()])
        transport.on("GET /api/v3/release", json: """
        [
          {"guid": "r1", "indexerId": 3, "indexer": "IPTorrents", "title": "Shogun.S01.1080p.WEB",
           "quality": {"quality": {"name": "WEBDL-1080p"}}, "size": 30000000000, "seeders": 5, "leechers": 1,
           "ageHours": 36, "rejected": true, "rejections": ["Existing file is better"], "releaseGroup": "",
           "customFormatScore": 0, "customFormats": [], "languages": [{"id": 1, "name": "English"}],
           "protocol": "torrent", "fullSeason": true, "infoUrl": ""},
          {"guid": "r2", "indexerId": 3, "title": "Shogun.S01.2160p", "seeders": 2, "rejected": false,
           "customFormats": [{"name": "HDR"}, {"name": ""}], "protocol": "usenet"},
          {"guid": "r3", "indexerId": 4, "title": "Shogun.S01.720p", "seeders": 40},
          {"guid": "r4", "indexerId": 4, "title": "Shogun.S01.480p", "seeders": 2}
        ]
        """)
        let releases = try await direct.releases(.season(series: 12, season: 1))
        #expect(releases.map(\.guid) == ["r3", "r2", "r4", "r1"])
        let rejected = releases[3]
        #expect(rejected.approved == false)
        #expect(rejected.rejections == ["Existing file is better"])
        #expect(rejected.quality == "WEBDL-1080p")
        #expect(rejected.age_days == 1.5)
        #expect(rejected.release_group == nil)
        #expect(rejected.info_url == nil)
        #expect(rejected.languages == ["English"])
        #expect(rejected.full_season == true)
        #expect(rejected._protocol == "torrent")
        #expect(releases[1].custom_formats == ["HDR"])
        #expect(releases[0].approved == true)
        #expect(releases[0].rejections == [])
        #expect(releases[0].age_days == nil)

        let request = try #require(transport.requests.first)
        #expect(request.url?.query() == "seasonNumber=1&seriesId=12")
        #expect(request.timeoutInterval == 90)
    }

    @Test func aGrabIsSentOnceWithTheIndexer() async throws {
        let (direct, transport) = backend(["radarr": .arr("http://10.0.0.5:7878")])
        transport.on("POST /api/v3/release", json: "{}")
        try await direct.grabArrRelease(.radarr, guid: "abc", indexerID: 3)
        let sent = try JSON(data: try #require(transport.requests.first?.httpBody))
        #expect(sent == ["guid": "abc", "indexerId": 3])
    }

    @Test func eachTargetAsksItsArr() async throws {
        let (direct, transport) = backend([
            "radarr": .arr("http://10.0.0.5:7878"), "readarr": .arr("http://10.0.0.5:8787"),
            "lidarr": .arr("http://10.0.0.5:8686"), "sonarr": .arr(),
        ])
        transport.on("GET /api/v3/release", json: "[]")
        transport.on("GET /api/v1/release", json: "[]")
        _ = try await direct.releases(.movie(5))
        _ = try await direct.releases(.episode(series: 1, episode: 99))
        _ = try await direct.releases(.book(6))
        _ = try await direct.releases(.album(7))
        #expect(transport.requests.map { "\($0.url?.port ?? 0)?\($0.url?.query() ?? "")" } == [
            "7878?movieId=5", "8989?episodeId=99", "8787?bookId=6", "8686?albumId=7",
        ])
    }
}

struct RenameTests {
    @Test func previewRowsCarryTheFileID() async throws {
        let (direct, transport) = backend(["radarr": .arr("http://10.0.0.5:7878")])
        transport.on("GET /api/v3/rename", json: """
        [{"movieId": 5, "movieFileId": 77, "existingPath": "dune.mkv", "newPath": "Dune (2021) [2160p].mkv"}]
        """)
        let previews = try await direct.renamePreview(.movie(5))
        #expect(previews == [RenamePreview(existing_path: "dune.mkv", file_id: 77, new_path: "Dune (2021) [2160p].mkv")])
        #expect(transport.requests.first?.url?.query() == "movieId=5")
    }

    @Test func renamingSendsTheCommandAndRefusesNothing() async throws {
        let (direct, transport) = backend(["sonarr": .arr()])
        transport.on("POST /api/v3/command", json: #"{"id": 1}"#)
        try await direct.renameFiles(.series(12), fileIDs: [1, 2])
        let sent = try JSON(data: try #require(transport.requests.first?.httpBody))
        #expect(sent == ["name": "RenameFiles", "seriesId": 12, "files": [1, 2]])
        await #expect(throws: APIError.refused("nothing to rename")) {
            try await direct.renameFiles(.series(12), fileIDs: [])
        }
        await #expect(throws: APIError.refused("unknown app 'readarr'")) {
            try await direct.renamePreview(.book(3))
        }
    }
}

struct BulkTests {
    @Test func bulkEditTellsTheArrWhatToDoWithTheTags() async throws {
        let (direct, transport) = backend(["lidarr": .arr("http://10.0.0.5:8686")])
        transport.on("PUT /api/v1/artist/editor", json: "[]")
        direct.cache.set("lidarr:artists", [1, 2])
        try await direct.bulkEdit(.lidarr, ids: [1, 2], monitored: false, qualityProfile: nil, tags: [4], tagChange: nil)
        let request = try #require(transport.requests.first)
        #expect(try JSON(data: request.httpBody ?? Data()) == [
            "artistIds": [1, 2], "monitored": false, "tags": [4], "applyTags": "add",
        ])
        #expect(request.timeoutInterval == 30)
        // the next read of the artists goes to Lidarr
        let cached: [Int]? = direct.cache.fresh("lidarr:artists", ttl: 60)
        #expect(cached == nil)
    }

    @Test func bulkEditLeavesOutWhatIsNotChanging() async throws {
        let (direct, transport) = backend(["radarr": .arr("http://10.0.0.5:7878")])
        transport.on("PUT /api/v3/movie/editor", json: "[]")
        try await direct.bulkEdit(.radarr, ids: [3], monitored: nil, qualityProfile: 6, tags: nil, tagChange: .remove)
        #expect(try JSON(data: transport.requests.first?.httpBody ?? Data()) == ["movieIds": [3], "qualityProfileId": 6])
    }

    @Test func bulkDeleteUsesEachArrsExclusionFlag() async throws {
        let (direct, transport) = backend(["radarr": .arr("http://10.0.0.5:7878"), "sonarr": .arr()])
        transport.on("DELETE /api/v3/movie/editor", json: "")
        transport.on("DELETE /api/v3/series/editor", json: "")
        try await direct.bulkDelete(.radarr, ids: [1], deleteFiles: true)
        try await direct.bulkDelete(.sonarr, ids: [2], deleteFiles: false)
        let bodies = try transport.requests.map { try JSON(data: $0.httpBody ?? Data()) }
        #expect(bodies == [
            ["movieIds": [1], "deleteFiles": true, "addImportExclusion": false],
            ["seriesIds": [2], "deleteFiles": false, "addImportListExclusion": false],
        ])
    }

    @Test func bulkSearchIsOneCommandOrOnePerTitle() async throws {
        let (direct, transport) = backend(["radarr": .arr("http://10.0.0.5:7878"), "sonarr": .arr()])
        transport.on("POST /api/v3/command", json: #"{"id": 1}"#)
        try await direct.bulkSearch(.radarr, ids: [1, 2])
        try await direct.bulkSearch(.sonarr, ids: [3, 4])
        let bodies = try transport.requests.map { try JSON(data: $0.httpBody ?? Data()) }
        #expect(bodies == [
            ["name": "MoviesSearch", "movieIds": [1, 2]],
            ["name": "SeriesSearch", "seriesId": 3],
            ["name": "SeriesSearch", "seriesId": 4],
        ])
    }
}
