import ArrdeckAPI
import ArrdeckData
import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

// MARK: - the decision

@Suite struct PrefsSyncPolicyTests {
    func decide(server: Int = 0, synced: Int = 0, changed: Int = 0, local: Bool = false) -> SyncAction {
        PrefsSyncPolicy.decide(serverAt: server, syncedAt: synced, changedAt: changed, hasLocalValues: local)
    }

    @Test func aServerCopyNewerThanTheLastSyncIsApplied() {
        #expect(decide(server: 5000, synced: 4000) == .apply)
        #expect(decide(server: 5000) == .apply)
    }

    @Test func aDeviceWhoseChoicesWereNeverSyncedTakesTheServersCopy() {
        #expect(decide(server: 5000, local: true) == .apply)
    }

    @Test func equalMeansNothingToDo() {
        #expect(decide(server: 5000, synced: 5000, local: true) == .none)
        #expect(decide() == .none)
    }

    @Test func aLocalChangeTheServerHasNotSeenIsPushed() {
        #expect(decide(server: 4000, synced: 4000, changed: 4500) == .push)
        #expect(decide(changed: 4500, local: true) == .push)
    }

    @Test func theLaterWriteWinsWhenBothSidesChanged() {
        #expect(decide(server: 6000, synced: 3000, changed: 5000, local: true) == .apply)
        #expect(decide(server: 5000, synced: 3000, changed: 6000, local: true) == .push)
    }

    @Test func aDeviceWithChoicesSeedsAnEmptyServer() {
        #expect(decide(local: true) == .push)
    }

    @Test func aDeviceWithOnlyDefaultsNeverSeedsTheServer() {
        #expect(decide(server: 0, local: false) == .none)
    }

    @Test func aServerThatFellBehindIsRestoredFromTheDeviceThatHasChoices() {
        #expect(decide(server: 2000, synced: 5000, local: true) == .push)
        #expect(decide(server: 2000, synced: 5000, local: false) == .none)
    }
}

// MARK: - the mapping

@Suite struct DisplaySyncTests {
    func fresh() -> UserDefaults {
        let name = "prefs-sync-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func aDeviceOnDefaultsCollectsEveryKeyTheWebAppHasWithItsDefault() {
        let values = DisplaySync.collect(fresh())
        #expect(values.count == 15)
        #expect(Set(values.keys) == DisplaySync.keys)
        #expect(values["layout.movies"] == .string("posters"))
        #expect(values["layout.series"] == .string("posters"))
        #expect(values["layout.books"] == .string("posters"))
        #expect(values["unmonitored.movies"] == .string("show"))
        #expect(values["startTab"] == .string(""))
        #expect(values["tabOrder"] == .strings([]))
        #expect(values["hiddenTabs"] == .strings([]))
        #expect(values["dates"] == .string("relative"))
        #expect(values["sizes"] == .string("binary"))
        #expect(values["spoilers"] == .string("off"))
        #expect(values["confirm"] == .string("deletes"))
        #expect(values["theme"] == .string("system"))
        #expect(values["palette"] == .string("arrdeck"))
    }

    @Test func collectingWritesNothingAndDefaultsAreNotChoices() {
        let defaults = fresh()
        #expect(!DisplaySync.hasLocalValues(defaults))
        _ = DisplaySync.collect(defaults)
        #expect(!DisplaySync.hasLocalValues(defaults))
        defaults.set("dim", forKey: DisplayKeys.unmonitored(.sonarr))
        #expect(DisplaySync.hasLocalValues(defaults))
    }

    @Test func eachTabMapsToTheWebRoute() {
        let defaults = fresh()
        defaults.set("shows", forKey: DisplayKeys.startTab)
        defaults.set("books,movies,shows,activity,calendar,settings", forKey: DisplayKeys.tabOrder)
        defaults.set("calendar,activity", forKey: DisplayKeys.hiddenTabs)
        let values = DisplaySync.collect(defaults)
        #expect(values["startTab"] == .string("/shows"))
        #expect(values["tabOrder"] == .strings(["/books", "/movies", "/shows", "/activity", "/calendar", "/settings"]))
        #expect(values["hiddenTabs"] == .strings(["/calendar", "/activity"]))
    }

    @Test func appsMapToTheWebsKinds() {
        let defaults = fresh()
        defaults.set("details", forKey: DisplayKeys.layout(.radarr))
        defaults.set("upnext", forKey: DisplayKeys.layout(.sonarr))
        defaults.set("shelf", forKey: DisplayKeys.layout(.readarr))
        defaults.set("hide", forKey: DisplayKeys.unmonitored(.radarr))
        defaults.set("dim", forKey: DisplayKeys.unmonitored(.sonarr))
        defaults.set("show", forKey: DisplayKeys.unmonitored(.readarr))
        let values = DisplaySync.collect(defaults)
        #expect(values["layout.movies"] == .string("details"))
        #expect(values["layout.series"] == .string("upnext"))
        #expect(values["layout.books"] == .string("shelf"))
        #expect(values["unmonitored.movies"] == .string("hide"))
        #expect(values["unmonitored.series"] == .string("dim"))
        #expect(values["unmonitored.books"] == .string("show"))
    }

    @Test func serverValuesLandInStorageAsThisAppKeepsThem() {
        let defaults = fresh()
        DisplaySync.apply([
            "layout.movies": .string("collections"), "layout.series": .string("upnext"), "layout.books": .string("shelf"),
            "unmonitored.movies": .string("hide"),
            "startTab": .string("/calendar"),
            "tabOrder": .strings(["/shows", "/books", "/movies"]),
            "hiddenTabs": .strings(["/activity"]),
            "dates": .string("absolute"), "sizes": .string("decimal"), "spoilers": .string("unwatched"), "confirm": .string("never"),
            "theme": .string("light"), "palette": .string("tokyonight"),
        ], to: defaults)
        #expect(defaults.string(forKey: DisplayKeys.layout(.radarr)) == "collections")
        #expect(defaults.pref(DisplayKeys.layout(.sonarr), default: LibraryLayout.posters) == .upNext)
        #expect(defaults.string(forKey: DisplayKeys.layout(.readarr)) == "shelf")
        #expect(defaults.string(forKey: DisplayKeys.unmonitored(.radarr)) == "hide")
        #expect(defaults.string(forKey: DisplayKeys.startTab) == "calendar")
        #expect(defaults.string(forKey: DisplayKeys.tabOrder) == "shows,books,movies")
        #expect(defaults.string(forKey: DisplayKeys.hiddenTabs) == "activity")
        #expect(defaults.string(forKey: DisplayKeys.dates) == "absolute")
        #expect(defaults.string(forKey: DisplayKeys.sizes) == "decimal")
        #expect(defaults.string(forKey: DisplayKeys.spoilers) == "unwatched")
        #expect(defaults.string(forKey: DisplayKeys.confirm) == "never")
        #expect(defaults.string(forKey: DisplayKeys.appearance) == "light")
        #expect(defaults.string(forKey: DisplayKeys.palette) == "tokyonight")
    }

    @Test func whatThisAppCannotShowIsIgnoredAndWhatTheServerOmittedIsLeftAlone() {
        let defaults = fresh()
        defaults.set("dim", forKey: DisplayKeys.unmonitored(.radarr))
        defaults.set("calendar", forKey: DisplayKeys.startTab)
        DisplaySync.apply([
            "layout.movies": .string("upnext"),          // a Shows-only layout
            "layout.series": .string("holographic"),     // from a newer client
            "startTab": .string("/nowhere"),
            "tabOrder": .strings(["/nowhere", "/movies"]),
            "dates": .string("tomorrow"), "theme": .string("neon"), "palette": .string("vaporwave"),
            "confirm": .int(3),
        ], to: defaults)
        #expect(defaults.string(forKey: DisplayKeys.layout(.radarr)) == nil)
        #expect(defaults.string(forKey: DisplayKeys.layout(.sonarr)) == nil)
        #expect(defaults.string(forKey: DisplayKeys.startTab) == "calendar")
        #expect(defaults.string(forKey: DisplayKeys.tabOrder) == "movies")
        #expect(defaults.string(forKey: DisplayKeys.dates) == nil)
        #expect(defaults.string(forKey: DisplayKeys.appearance) == nil)
        #expect(defaults.string(forKey: DisplayKeys.palette) == nil)
        #expect(defaults.string(forKey: DisplayKeys.confirm) == nil)
        // untouched: the server did not send it
        #expect(defaults.string(forKey: DisplayKeys.unmonitored(.radarr)) == "dim")
    }

    @Test func anEmptyStartTabResetsToTheDefault() {
        let defaults = fresh()
        defaults.set("movies", forKey: DisplayKeys.startTab)
        DisplaySync.apply(["startTab": .string("")], to: defaults)
        #expect(defaults.string(forKey: DisplayKeys.startTab) == "")
    }

    @Test func collectedValuesApplyBackToTheSameChoices() {
        let source = fresh()
        source.set("list", forKey: DisplayKeys.layout(.radarr))
        source.set("seasons", forKey: DisplayKeys.layout(.sonarr))
        source.set("movies", forKey: DisplayKeys.startTab)
        source.set("shows,movies", forKey: DisplayKeys.tabOrder)
        source.set("dark", forKey: DisplayKeys.appearance)
        source.set("nord", forKey: DisplayKeys.palette)
        let target = fresh()
        DisplaySync.apply(DisplaySync.collect(source), to: target)
        #expect(DisplaySync.collect(target) == DisplaySync.collect(source))
    }

    @Test func theLanguageStaysOnTheDevice() {
        let defaults = fresh()
        defaults.set("da", forKey: "display.language")
        #expect(DisplaySync.collect(defaults).keys.contains { $0.lowercased().contains("lang") } == false)
        DisplaySync.apply(["language": .string("en")], to: defaults)
        #expect(defaults.string(forKey: "display.language") == "da")
        #expect(!DisplaySync.hasLocalValues(defaults))
    }
}

// MARK: - the wire

/// Records what the client sends and answers each path from a table.
final class RecordingTransport: ClientTransport, @unchecked Sendable {
    var responses: [String: String]
    private(set) var sent: [(method: String, body: String)] = []

    init(_ responses: [String: String]) { self.responses = responses }

    func send(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String) async throws -> (HTTPResponse, HTTPBody?) {
        let text: String
        if let body { text = String(decoding: try await Data(collecting: body, upTo: 1 << 20), as: UTF8.self) } else { text = "" }
        sent.append((request.method.rawValue, text))
        var response = HTTPResponse(status: .ok)
        response.headerFields[.contentType] = "application/json"
        return (response, HTTPBody(responses[request.path ?? ""] ?? "{}"))
    }
}

@Suite struct PrefsWireTests {
    @Test func theServersSetDecodesWithArraysNumbersAndBooleans() async throws {
        let body = """
        {"values":{"startTab":"/calendar","tabOrder":["/books","/movies"],"hiddenTabs":[],"flag":true,"n":3,"x":1.5,"gone":null},"updated_at":1791663072982}
        """
        let api = LiveAPI(client: Client(serverURL: URL(string: "http://stub")!, transport: RecordingTransport(["/api/v1/prefs": body])))
        let stored = try await api.prefs()
        #expect(stored.updatedAt == 1_791_663_072_982)
        #expect(stored.values["startTab"] == .string("/calendar"))
        #expect(stored.values["tabOrder"] == .strings(["/books", "/movies"]))
        #expect(stored.values["hiddenTabs"] == .strings([]))
        #expect(stored.values["flag"] == .bool(true))
        #expect(stored.values["n"] == .int(3))
        #expect(stored.values["x"] == .double(1.5))
        #expect(stored.values["gone"] == PrefValue.null)
    }

    @Test func anEmptyServerReadsAsNothingAtTimeZero() async throws {
        let api = LiveAPI(client: Client(serverURL: URL(string: "http://stub")!, transport: RecordingTransport(["/api/v1/prefs": #"{"values":{},"updated_at":0}"#])))
        #expect(try await api.prefs() == StoredPrefs())
    }

    @Test func aPutSendsEveryValueIncludingOnesItDoesNotKnow() async throws {
        let transport = RecordingTransport(["/api/v1/prefs": #"{"values":{"dates":"absolute"},"updated_at":42}"#])
        let api = LiveAPI(client: Client(serverURL: URL(string: "http://stub")!, transport: transport))
        let stored = try await api.putPrefs(
            values: ["dates": .string("absolute"), "tabOrder": .strings(["/books"]), "fromTheFuture": .bool(true), "n": .int(7)],
            updatedAt: 42
        )
        #expect(stored.updatedAt == 42)
        let (method, body) = try #require(transport.sent.first)
        #expect(method == "PUT")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        #expect(json["updated_at"] as? Int == 42)
        let values = try #require(json["values"] as? [String: Any])
        #expect(values["dates"] as? String == "absolute")
        #expect(values["tabOrder"] as? [String] == ["/books"])
        #expect(values["fromTheFuture"] as? Bool == true)
        #expect(values["n"] as? Int == 7)
    }
}

// MARK: - the sync

/// A server that keeps the rules the real one states: the newer write wins,
/// every answer is what is stored now, and a time in the future is clamped.
actor FakePrefsServer: PrefsAPI {
    var stored: StoredPrefs
    var clock = 10_000_000
    var failure: APIError?
    var beforePut: (@Sendable () async -> Void)?
    var latency = Duration.zero
    private(set) var gets = 0
    private(set) var puts: [StoredPrefs] = []
    private(set) var inFlight = 0
    private(set) var mostInFlight = 0

    init(_ stored: StoredPrefs = StoredPrefs()) { self.stored = stored }

    func set(failure: APIError?) { self.failure = failure }
    func set(stored: StoredPrefs) { self.stored = stored }
    func set(beforePut: (@Sendable () async -> Void)?) { self.beforePut = beforePut }
    func set(latency: Duration) { self.latency = latency }

    func prefs() async throws -> StoredPrefs {
        gets += 1
        inFlight += 1
        mostInFlight = max(mostInFlight, inFlight)
        defer { inFlight -= 1 }
        if latency > .zero { try await Task.sleep(for: latency) }
        if let failure { throw failure }
        return stored
    }

    func putPrefs(values: [String: PrefValue], updatedAt: Int) async throws -> StoredPrefs {
        if let failure { throw failure }
        if let beforePut { await beforePut() }
        let at = min(updatedAt, clock)
        puts.append(StoredPrefs(values: values, updatedAt: updatedAt))
        if at >= stored.updatedAt { stored = StoredPrefs(values: values, updatedAt: at) }
        return stored
    }
}

@MainActor final class Clock { var ms = 2_000_000 }

@MainActor
@Suite struct PrefsSyncModelTests {
    let defaults: UserDefaults
    let clock = Clock()
    let profile = UUID()
    var applied = 0

    init() {
        let name = "prefs-sync-model-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
    }

    func model(_ server: FakePrefsServer, onApplied: @escaping @MainActor () -> Void = {}) -> PrefsSyncModel {
        let clock = clock
        return PrefsSyncModel(api: server, profileID: profile, defaults: defaults, debounce: .milliseconds(10),
                              now: { clock.ms }, onApplied: onApplied)
    }

    @Test func aDeviceWithOnlyDefaultsLeavesAnEmptyServerAlone() async {
        let server = FakePrefsServer()
        let model = model(server)
        await model.sync()
        #expect(await server.gets == 1)
        #expect(await server.puts.isEmpty)
        #expect(model.syncedAt == 0)
        #expect(model.changedAt == 0)
    }

    @Test func aNewerServerCopyIsAppliedAndTheThemeIsToldToReload() async {
        let server = FakePrefsServer(StoredPrefs(values: ["dates": .string("absolute"), "theme": .string("light"), "palette": .string("nord")], updatedAt: 5000))
        let box = Box()
        let model = model(server) { box.applied += 1 }
        await model.sync()
        #expect(defaults.string(forKey: DisplayKeys.dates) == "absolute")
        #expect(defaults.string(forKey: DisplayKeys.appearance) == "light")
        #expect(defaults.string(forKey: DisplayKeys.palette) == "nord")
        #expect(model.syncedAt == 5000)
        #expect(model.changedAt == 0)
        #expect(box.applied == 1)
        #expect(await server.puts.isEmpty)
    }

    @Test func applyingServerValuesIsNotTakenForALocalChange() async {
        let server = FakePrefsServer(StoredPrefs(values: ["dates": .string("absolute")], updatedAt: 5000))
        let model = model(server)
        await model.sync()
        // the notification UserDefaults posts for what was just written
        model.noteLocalChange()
        #expect(model.changedAt == 0)
    }

    @Test func aLocalChangeIsPushedWithTheServersUnknownKeysAndTheReturnedTimeIsRecorded() async {
        let server = FakePrefsServer(StoredPrefs(values: ["dates": .string("relative"), "fromANewerClient": .strings(["a", "b"])], updatedAt: 5000))
        let model = model(server)
        await model.sync()
        defaults.set("decimal", forKey: DisplayKeys.sizes)
        clock.ms = 7000
        model.noteLocalChange()
        #expect(model.changedAt == 7000)
        await model.sync()
        let sent = await server.puts
        #expect(sent.count == 1)
        #expect(sent[0].updatedAt == 7000)
        #expect(sent[0].values["sizes"] == .string("decimal"))
        #expect(sent[0].values["fromANewerClient"] == .strings(["a", "b"]))
        // the full set, defaults included, as the web app sends it
        #expect(sent[0].values.count == DisplaySync.keys.count + 1)
        #expect(model.syncedAt == 7000)
        #expect(model.changedAt == 0)
    }

    @Test func aNoteForAnUnchangedChoiceIsNotAChange() async {
        let model = model(FakePrefsServer())
        model.noteLocalChange()
        defaults.set("unrelated", forKey: "something.else")
        model.noteLocalChange()
        #expect(model.changedAt == 0)
    }

    @Test func changesInTheSameMillisecondStayOrderedAndNeverPrecedeTheSyncedCopy() async {
        let server = FakePrefsServer(StoredPrefs(values: [:], updatedAt: 9000))
        let model = model(server)
        await model.sync()
        // this device's clock is behind the server's
        clock.ms = 100
        defaults.set("list", forKey: DisplayKeys.layout(.radarr))
        model.noteLocalChange()
        #expect(model.changedAt == 9001)
        defaults.set("details", forKey: DisplayKeys.layout(.radarr))
        model.noteLocalChange()
        #expect(model.changedAt == 9002)
    }

    @Test func aWriteThatLostAdoptsWhatTheServerNowHolds() async {
        let server = FakePrefsServer(StoredPrefs(values: [:], updatedAt: 1000))
        let other = StoredPrefs(values: ["sizes": .string("binary"), "dates": .string("absolute")], updatedAt: 8000)
        await server.set(beforePut: { [server] in await server.set(stored: other) })
        let model = model(server)
        await model.sync()
        defaults.set("decimal", forKey: DisplayKeys.sizes)
        clock.ms = 3000
        model.noteLocalChange()
        await model.sync()
        // another device wrote in between, later than ours
        #expect(defaults.string(forKey: DisplayKeys.sizes) == "binary")
        #expect(defaults.string(forKey: DisplayKeys.dates) == "absolute")
        #expect(model.syncedAt == 8000)
        #expect(model.changedAt == 0)
    }

    @Test func aTimeInTheFutureIsRecordedAsTheServersClampedTime() async {
        let server = FakePrefsServer(StoredPrefs(values: [:], updatedAt: 1000))
        let model = model(server)
        await model.sync()
        clock.ms = 50_000_000   // the server's clock says 10_000_000
        defaults.set("never", forKey: DisplayKeys.confirm)
        model.noteLocalChange()
        await model.sync()
        #expect(await server.stored.updatedAt == 10_000_000)
        #expect(defaults.string(forKey: DisplayKeys.confirm) == "never")
        #expect(model.syncedAt == 10_000_000)
        #expect(model.changedAt == 0)
    }

    @Test func aFailedRequestLosesNothingAndTheChangeGoesOutNextTime() async {
        let server = FakePrefsServer(StoredPrefs(values: [:], updatedAt: 1000))
        let model = model(server)
        await model.sync()
        defaults.set("never", forKey: DisplayKeys.confirm)
        clock.ms = 3000
        model.noteLocalChange()
        await server.set(failure: .transport("offline"))
        await model.sync()
        #expect(model.changedAt == 3000)
        #expect(defaults.string(forKey: DisplayKeys.confirm) == "never")
        await server.set(failure: nil)
        await model.sync()
        #expect(model.changedAt == 0)
        #expect(await server.stored.values["confirm"] == .string("never"))
    }

    @Test func aNewerServerCopyBeatsAnOlderUnsentChange() async {
        let server = FakePrefsServer(StoredPrefs(values: [:], updatedAt: 1000))
        let model = model(server)
        await model.sync()
        defaults.set("never", forKey: DisplayKeys.confirm)
        clock.ms = 3000
        model.noteLocalChange()
        await server.set(stored: StoredPrefs(values: ["confirm": .string("always")], updatedAt: 4000))
        await model.sync()
        #expect(defaults.string(forKey: DisplayKeys.confirm) == "always")
        #expect(model.syncedAt == 4000)
        #expect(model.changedAt == 0)
        #expect(await server.puts.isEmpty)
    }

    @Test func aDeviceWithChoicesSeedsAnEmptyServer() async {
        let server = FakePrefsServer()
        defaults.set("dark", forKey: DisplayKeys.appearance)
        let model = model(server)
        await model.sync()
        #expect(await server.stored.values["theme"] == .string("dark"))
        #expect(model.syncedAt == 2_000_000)
    }

    @Test func aChangeMadeWhileTheRequestIsOutGoesRoundAgain() async {
        let server = FakePrefsServer(StoredPrefs(values: [:], updatedAt: 1000))
        let model = model(server)
        await model.sync()
        defaults.set("never", forKey: DisplayKeys.confirm)
        clock.ms = 3000
        model.noteLocalChange()
        // a test's stand-in for the user tapping while the request is out
        nonisolated(unsafe) let defaults = defaults
        let clock = clock
        await server.set(beforePut: { [server] in
            await server.set(beforePut: nil)
            await MainActor.run {
                defaults.set("light", forKey: DisplayKeys.appearance)
                clock.ms = 3500
                model.noteLocalChange()
            }
        })
        await model.sync()
        let stored = await server.stored
        #expect(stored.values["theme"] == .string("light"))
        #expect(stored.values["confirm"] == .string("never"))
        #expect(model.changedAt == 0)
        #expect(await server.puts.count == 2)
    }

    @Test func runsNeverOverlap() async {
        let server = FakePrefsServer(StoredPrefs(values: [:], updatedAt: 1000))
        await server.set(latency: .milliseconds(30))
        let model = model(server)
        async let first: Void = model.sync()
        async let second: Void = model.sync()
        _ = await (first, second)
        #expect(await server.mostInFlight == 1)
        // the second asked for another go once the first was done
        #expect(await server.gets == 2)
    }

    @Test func eachServerKeepsItsOwnSyncTimes() async {
        let one = FakePrefsServer(StoredPrefs(values: [:], updatedAt: 5000))
        let a = model(one)
        await a.sync()
        let b = PrefsSyncModel(api: FakePrefsServer(), profileID: UUID(), defaults: defaults)
        #expect(a.syncedAt == 5000)
        #expect(b.syncedAt == 0)
    }

    @Test func comingBackSoonDoesNotAskAgainButAfterAWhileItDoes() async throws {
        let server = FakePrefsServer(StoredPrefs(values: [:], updatedAt: 1000))
        let model = model(server)
        let running = Task { await model.run() }
        try await settle { await server.gets == 1 }
        clock.ms += 10_000
        model.refreshIfStale()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await server.gets == 1)
        clock.ms += 60_000
        model.refreshIfStale()
        try await settle { await server.gets == 2 }
        running.cancel()
        await running.value
    }

    @Test func aChangeWhileRunningIsSentAfterTheDebounce() async throws {
        let server = FakePrefsServer(StoredPrefs(values: [:], updatedAt: 1000))
        let model = model(server)
        let running = Task { await model.run() }
        try await settle { await server.gets == 1 }
        defaults.set("never", forKey: DisplayKeys.confirm)
        clock.ms += 1
        // UserDefaults posts its notification by itself; the model hears it
        try await settle { await server.puts.count == 1 }
        #expect(await server.stored.values["confirm"] == .string("never"))
        running.cancel()
        await running.value
    }

    /// Polls until `condition` holds, for the work that happens on its own tasks.
    func settle(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting")
    }
}

@MainActor final class Box { var applied = 0 }
