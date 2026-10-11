import ArrdeckAPI
import ArrdeckData
import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

private func candidate(
    _ path: String, importable: Bool = true, quality: Int? = 7, languages: [Int]? = [1]
) -> ImportCandidate {
    ImportCandidate(importable: importable, language_ids: languages, languages: languages?.map { "L\($0)" },
                    name: path, path: path, quality: quality.map { "Q\($0)" }, quality_id: quality,
                    rejections: importable ? [] : ["Unknown Movie"], size: 100, title: importable ? "Dune" : "")
}

@Suite struct ImportPicksTests {
    let placed = candidate("/dl/a.mkv")
    let unplaced = candidate("/dl/b.mkv", importable: false)
    let noQuality = candidate("/dl/c.mkv", quality: nil)

    @Test func readyNeedsAPlaceAndAQuality() {
        var picks = ImportPicks()
        #expect(picks.ready(placed))
        #expect(!picks.ready(unplaced))
        #expect(!picks.ready(noQuality))
        picks.assign(.movie(4, label: "Dune (2021)"), to: unplaced)
        #expect(picks.ready(unplaced))
        picks.setQuality(3, for: noQuality)
        #expect(picks.ready(noQuality))
    }

    @Test func onlyReadyFilesCanBePicked() {
        var picks = ImportPicks()
        let first = picks.toggle(placed)
        let refused = picks.toggle(unplaced)
        #expect(first && !refused)
        #expect(picks.picked == ["/dl/a.mkv"])
        let again = picks.toggle(placed)
        #expect(!again)
        #expect(picks.picked.isEmpty)
    }

    @Test func toggleAllTakesEveryReadyFileThenNone() {
        var picks = ImportPicks()
        let all = [placed, unplaced, noQuality]
        picks.toggleAll(all)
        #expect(picks.picked == ["/dl/a.mkv"])
        #expect(picks.allPicked(all))
        picks.toggleAll(all)
        #expect(picks.picked.isEmpty)
    }

    @Test func assigningPicksAndClearingAnUnplacedFileUnpicks() {
        var picks = ImportPicks()
        picks.assign(.movie(4, label: "Dune"), to: unplaced)
        #expect(picks.picked.contains(unplaced.path))
        picks.clearTarget(unplaced)
        #expect(!picks.picked.contains(unplaced.path))
        // a file the arr placed itself stays picked on its own match
        picks.toggle(placed)
        picks.assign(.movie(9, label: "Other"), to: placed)
        picks.clearTarget(placed)
        #expect(picks.picked.contains(placed.path))
    }

    @Test func overridesDefaultToTheDetection() {
        var picks = ImportPicks()
        #expect(picks.qualityID(placed) == 7)
        #expect(picks.languageIDs(placed) == [1])
        picks.setQuality(9, for: placed)
        #expect(picks.qualityID(placed) == 9)
        #expect(picks.isOverridden(placed))
        // choosing the detected quality again is no override at all
        picks.setQuality(7, for: placed)
        #expect(!picks.isOverridden(placed))
        #expect(picks.overrides.isEmpty)

        picks.toggleLanguage(2, for: placed)
        #expect(picks.languageIDs(placed) == [1, 2])
        // back to exactly what was detected: no override
        picks.toggleLanguage(2, for: placed)
        #expect(picks.overrides.isEmpty)
        // emptying the list keeps the detection rather than "no language"
        picks.toggleLanguage(1, for: placed)
        #expect(picks.overrides.isEmpty)
        #expect(picks.languageIDs(placed) == [1])

        picks.toggleLanguage(3, for: placed)
        picks.resetOverride(placed)
        #expect(picks.overrides.isEmpty)
    }

    @Test func nothingPickedIsNoRequest() {
        #expect(ImportPicks().request(for: .queue(app: .radarr, itemID: 5), candidates: [placed]) == nil)
    }

    @Test func untouchedQueueFilesGoToThePlainEndpoint() {
        var picks = ImportPicks()
        let other = candidate("/dl/d.mkv")
        picks.toggle(other)
        picks.toggle(placed)
        let request = picks.request(for: .queue(app: .radarr, itemID: 5), candidates: [placed, unplaced, other])
        // in the arr's order, not the order they were picked
        #expect(request == .plain(.radarr, .init(item_id: 5, mode: .auto, paths: ["/dl/a.mkv", "/dl/d.mkv"])))
    }

    @Test func aTargetSendsEveryPickedFileToAssign() {
        var picks = ImportPicks()
        picks.toggle(placed)
        picks.assign(.episodes(series: 3, ids: [11, 12], label: "Show S01E01–E02"), to: unplaced)
        picks.mode = .move
        let request = picks.request(for: .queue(app: .sonarr, itemID: 8), candidates: [placed, unplaced])
        #expect(request == .assign(.sonarr, .init(
            files: [
                .init(path: "/dl/a.mkv"),
                .init(episode_ids: [11, 12], path: "/dl/b.mkv", series_id: 3),
            ],
            item_id: 8, mode: .move
        )))
    }

    @Test func anOverrideAloneAlsoGoesToAssign() {
        var picks = ImportPicks()
        picks.toggle(placed)
        picks.setQuality(9, for: placed)
        picks.toggleLanguage(2, for: placed)
        picks.mode = .copy
        let request = picks.request(for: .queue(app: .radarr, itemID: 5), candidates: [placed])
        #expect(request == .assign(.radarr, .init(
            files: [.init(language_ids: [1, 2], path: "/dl/a.mkv", quality_id: 9)], item_id: 5, mode: .copy
        )))
    }

    @Test func aTorrentAlwaysGoesToTheTorrentEndpoint() {
        var picks = ImportPicks()
        picks.toggle(placed)
        picks.assign(.book(21, label: "Dune — Frank Herbert"), to: unplaced)
        let request = picks.request(
            for: .torrent(app: .readarr, client: .transmission, torrentID: "42"), candidates: [placed, unplaced]
        )
        #expect(request == .torrent(.readarr, .init(
            client: .transmission,
            files: [.init(path: "/dl/a.mkv"), .init(book_id: 21, path: "/dl/b.mkv")],
            mode: .auto, torrent_id: "42"
        )))
    }

    @Test func episodeLabels() {
        #expect(ImportTargetSearch.episodeLabel(series: "Show", season: 1, episodes: [2]) == "Show S01E02")
        #expect(ImportTargetSearch.episodeLabel(series: "Show", season: 10, episodes: [4, 3, 2]) == "Show S10E02–E04")
    }

    @Test func targetSearchMatchesTitleOrAuthor() {
        let books = [LibraryBook(author: "Frank Herbert", id: 1, title: "Dune"),
                     LibraryBook(author: "Ursula K. Le Guin", id: 2, title: "The Dispossessed")]
        #expect(ImportTargetSearch.books(books, query: "herbert").map(\.id) == [1])
        #expect(ImportTargetSearch.books(books, query: "").map(\.id) == [1, 2])
        let movies = [LibraryMovie(id: 1, title: "b"), LibraryMovie(id: 2, title: "A")]
        #expect(ImportTargetSearch.movies(movies, query: " ").map(\.id) == [2, 1])
    }
}

@Suite struct AttentionReasonTests {
    @Test func statusMessagesThenTheErrorWithoutRepeats() {
        let item = QueueItem(
            app: .sonarr, error_message: "Not an upgrade", id: 1, size: 1, size_left: 0, status: "completed",
            status_messages: [
                .init(messages: ["Not an upgrade", "Sample"], title: "Show.S01"),
                .init(messages: ["Unknown episode"], title: "Show.S01E05.mkv"),
                .init(messages: [], title: "Lonely title"),
            ],
            title: "Show.S01", tracked_state: "importPending", tracked_status: "warning"
        )
        #expect(item.attentionReasons == [
            "Not an upgrade", "Sample", "Show.S01E05.mkv: Unknown episode", "Lonely title",
        ])
        #expect(item.importable)
    }

    @Test func plainErrorsWhenThereIsNothingElse() {
        let item = QueueItem(app: .radarr, errors: ["Disk full"], id: 1, size: 1, size_left: 0, status: "warning",
                             title: "x", tracked_state: "imported")
        #expect(item.attentionReasons == ["Disk full"])
        #expect(!item.importable)
    }
}

/// Answers candidates and options, records each started request and plays
/// back a list of command states, one per poll.
actor FakeImportAPI: ManualImportAPI {
    var candidates: [ImportCandidate]
    var states: [ImportCommand]
    var startFailure: APIError?
    var pollFailures = 0
    private(set) var started: [ImportRequest] = []
    private(set) var polls = 0

    init(candidates: [ImportCandidate], states: [ImportCommand]) {
        self.candidates = candidates
        self.states = states
    }

    func set(startFailure: APIError?) { self.startFailure = startFailure }
    func set(pollFailures: Int) { self.pollFailures = pollFailures }

    func attention() async throws -> Attention { Attention(count: 0, items: [], unavailable: []) }
    func importCandidates(_ source: ImportSource) async throws -> [ImportCandidate] { candidates }
    func importOptions(_ app: ArrApp) async throws -> ImportOptions {
        ImportOptions(languages: [.init(id: 1, name: "English"), .init(id: 2, name: "Danish")],
                      qualities: [.init(id: 7, name: "WEBDL-1080p"), .init(id: 9, name: "Bluray-1080p")])
    }
    func startImport(_ request: ImportRequest) async throws -> ImportCommand {
        if let startFailure { throw startFailure }
        started.append(request)
        return ImportCommand(app: .radarr, done: false, id: 77, status: "queued")
    }
    func importCommand(app: ArrApp, id: Int) async throws -> ImportCommand {
        polls += 1
        if pollFailures > 0 {
            pollFailures -= 1
            throw APIError.transport("offline")
        }
        return states.isEmpty ? ImportCommand(app: .radarr, done: true, id: id, ok: true) : states.removeFirst()
    }
}

@MainActor @Suite struct ImportModelTests {
    func model(_ api: FakeImportAPI, source: ImportSource = .queue(app: .radarr, itemID: 5)) -> ImportModel {
        ImportModel(source: source, api: api, pollInterval: .zero, maxPolls: 20, onSessionLost: {})
    }

    @Test func startsThePickedRequestAndPollsUntilDone() async {
        let api = FakeImportAPI(candidates: [candidate("/dl/a.mkv"), candidate("/dl/b.mkv")], states: [
            .init(app: .radarr, done: false, id: 77, message: "Processing file 1 of 2", status: "started"),
            .init(app: .radarr, done: true, id: 77, imported: 2, message: "Manually imported 2 files", ok: true,
                  status: "completed"),
        ])
        let model = model(api)
        await model.load()
        #expect(model.list.count == 2)
        #expect(model.options?.qualities?.count == 2)
        model.picks.toggleAll(model.list)
        #expect(model.chosenCount == 2)
        await model.start()
        #expect(await api.started == [.plain(.radarr, .init(item_id: 5, mode: .auto, paths: ["/dl/a.mkv", "/dl/b.mkv"]))])
        #expect(await api.polls == 2)
        #expect(model.finished)
        #expect(model.outcome == .succeeded("Radarr processed 2 files"))
        // one import per sheet
        await model.start()
        #expect(await api.started.count == 1)
    }

    @Test func aFailedCommandShowsTheArrsMessage() async {
        let api = FakeImportAPI(candidates: [candidate("/dl/a.mkv")], states: [
            .init(app: .radarr, done: true, id: 77, message: "Destination already exists", ok: false, status: "failed"),
        ])
        let model = model(api)
        await model.load()
        model.picks.toggleAll(model.list)
        await model.start()
        #expect(model.outcome == .failed("Destination already exists"))
    }

    @Test func aRefusalToStartIsShownAsTheServerWordsIt() async {
        let api = FakeImportAPI(candidates: [candidate("/dl/a.mkv")], states: [])
        await api.set(startFailure: .refused("none of the selected files could be mapped"))
        let model = model(api)
        await model.load()
        model.picks.toggleAll(model.list)
        await model.start()
        #expect(model.actionError == "none of the selected files could be mapped")
        #expect(model.command == nil)
        #expect(!model.started)
    }

    @Test func aPollHiccupIsRetriedAndThreeInARowStopTheWait() async {
        let api = FakeImportAPI(candidates: [candidate("/dl/a.mkv")], states: [])
        await api.set(pollFailures: 2)
        let model = model(api)
        await model.load()
        model.picks.toggleAll(model.list)
        await model.start()
        #expect(model.finished)
        #expect(model.actionError == nil)

        let stuck = FakeImportAPI(candidates: [candidate("/dl/a.mkv")], states: [])
        await stuck.set(pollFailures: 5)
        let waiting = self.model(stuck)
        await waiting.load()
        waiting.picks.toggleAll(waiting.list)
        await waiting.start()
        #expect(!waiting.finished)
        #expect(waiting.actionError == "offline")
        #expect(waiting.outcome == .running(nil))
    }

    @Test func overriddenNamesComeFromTheOptions() async {
        let api = FakeImportAPI(candidates: [candidate("/dl/a.mkv")], states: [])
        let model = model(api, source: .torrent(app: .radarr, client: .qbittorrent, torrentID: "abc"))
        await model.load()
        let file = model.list[0]
        #expect(model.qualityName(file) == "Q7")
        model.picks.setQuality(9, for: file)
        model.picks.toggleLanguage(2, for: file)
        #expect(model.qualityName(file) == "Bluray-1080p")
        #expect(model.languageNames(file) == ["English", "Danish"])
    }
}

/// Keeps every request's path and JSON body, and answers from a table.
final class ImportRecordingTransport: ClientTransport, @unchecked Sendable {
    struct Route: Sendable {
        var status = 200
        var body: String
    }

    let routes: [String: Route]
    private let lock = NSLock()
    private var sent: [(String, String)] = []

    init(routes: [String: Route]) { self.routes = routes }

    var requests: [(path: String, body: String)] {
        lock.withLock { sent.map { (path: $0.0, body: $0.1) } }
    }

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let path = request.path ?? ""
        let text = if let body { try await String(collecting: body, upTo: 1 << 20) } else { "" }
        lock.withLock { sent.append((path, text)) }
        let route = routes[path] ?? Route(status: 404, body: #"{"detail": "Not Found"}"#)
        var response = HTTPResponse(status: .init(code: route.status))
        response.headerFields[.contentType] = "application/json"
        return (response, HTTPBody(route.body))
    }
}

@Suite struct ManualImportWireTests {
    func api(_ transport: ImportRecordingTransport) -> LiveAPI {
        LiveAPI(client: Client(serverURL: URL(string: "http://stub")!, transport: transport))
    }

    func json(_ text: String) throws -> NSDictionary {
        try JSONSerialization.jsonObject(with: Data(text.utf8)) as! NSDictionary
    }

    @Test func eachRequestReachesItsEndpointWithItsPayload() async throws {
        let command = #"{"app": "radarr", "id": 5, "status": "queued", "done": false}"#
        let transport = ImportRecordingTransport(routes: [
            "/api/v1/manual-import/radarr": .init(body: command),
            "/api/v1/manual-import/sonarr/assign": .init(body: command),
            "/api/v1/manual-import/readarr/torrent": .init(body: command),
        ])
        let api = api(transport)
        _ = try await api.startImport(.plain(.radarr, .init(item_id: 3, mode: .auto, paths: ["/a"])))
        _ = try await api.startImport(.assign(.sonarr, .init(
            files: [.init(episode_ids: [1, 2], path: "/b", series_id: 4)], item_id: 9, mode: .move
        )))
        _ = try await api.startImport(.torrent(.readarr, .init(
            client: .qbittorrent, files: [.init(book_id: 6, path: "/c", quality_id: 2)], mode: .copy, torrent_id: "ff"
        )))
        let sent = transport.requests
        #expect(sent.map(\.path) == [
            "/api/v1/manual-import/radarr", "/api/v1/manual-import/sonarr/assign", "/api/v1/manual-import/readarr/torrent",
        ])
        #expect(try json(sent[0].body) == ["item_id": 3, "mode": "auto", "paths": ["/a"]] as NSDictionary)
        #expect(try json(sent[1].body) == [
            "item_id": 9, "mode": "move", "files": [["path": "/b", "series_id": 4, "episode_ids": [1, 2]]],
        ] as NSDictionary)
        #expect(try json(sent[2].body) == [
            "client": "qbittorrent", "torrent_id": "ff", "mode": "copy",
            "files": [["path": "/c", "book_id": 6, "quality_id": 2]],
        ] as NSDictionary)
    }

    @Test func aConflictCarriesTheServersSentence() async {
        let transport = ImportRecordingTransport(routes: [
            "/api/v1/manual-import/radarr/torrent/transmission/12": .init(
                status: 409, body: #"{"detail": "the torrent has not finished downloading"}"#
            ),
            "/api/v1/manual-import/sonarr/command/3": .init(status: 502, body: "Bad Gateway"),
        ])
        let api = api(transport)
        await #expect(throws: APIError.refused("the torrent has not finished downloading")) {
            try await api.importCandidates(.torrent(app: .radarr, client: .transmission, torrentID: "12"))
        }
        await #expect(throws: APIError.unexpectedStatus(502)) { try await api.importCommand(app: .sonarr, id: 3) }
    }
}

/// The Downloads fake, able to say what needs attention: as on a server
/// with the endpoint, where the model asks for it alongside the queue.
extension FakeDownloadsAPI: ManualImportAPI {
    func attention() async throws -> Attention {
        Attention(count: 1, items: [QueueItem(app: .radarr, id: 3, size: 1, size_left: 0, status: "completed",
                                              title: "Dune", tracked_state: "importBlocked")], unavailable: [])
    }
    func importCandidates(_ source: ImportSource) async throws -> [ImportCandidate] { [] }
    func importOptions(_ app: ArrApp) async throws -> ImportOptions { ImportOptions() }
    func startImport(_ request: ImportRequest) async throws -> ImportCommand { throw APIError.unexpectedStatus(500) }
    func importCommand(app: ArrApp, id: Int) async throws -> ImportCommand { throw APIError.unexpectedStatus(500) }
}

@MainActor @Suite struct DownloadsAttentionTests {
    @Test func needsAttentionIsFetchedWithTheQueue() async {
        let api = FakeDownloadsAPI(groups: [:])
        let model = DownloadsModel(api: api, clients: [], hasArr: true, arrs: [.radarr], onSessionLost: {})
        #expect(model.attentionCount == 0)
        await model.refreshQueue()
        #expect(model.attentionCount == 1)
        #expect(model.attentionItems.map(\.title) == ["Dune"])
        #expect(model.arrs == [.radarr])
    }
}
