import ArrdeckAPI
import Foundation
import Testing
@testable import ArrdeckData

@Suite struct RuleDraftTests {
    @Test func aNewRuleIsOffWithTheDefaultGraceAndNothingTicked() {
        let draft = RuleDraft()
        #expect(draft.isNew && !draft.enabled)
        #expect(draft.graceDays == 14)
        #expect(!draft.hasConditions && !draft.canSave)
        #expect(draft.probe == nil, "no conditions, no preview: the server would match nothing")
    }

    @Test func tickingStartsAtTheUsualValueAndValuesStayInTheServersBounds() {
        var draft = RuleDraft()
        draft.tick(.watched, true)
        #expect(draft.watchedDays == 180)
        draft.set(.watched, 0)
        #expect(draft.watchedDays == 1)
        draft.set(.unwatched, 9999)
        #expect(draft.unwatchedDays == 3650)
        draft.set(.rating, 12)
        #expect(draft.ratingBelow == 10)
        draft.set(.size, 0)
        #expect(draft.minSizeGB == 0.1)
        draft.tick(.watched, false)
        #expect(draft.watchedDays == nil)
        draft.graceDays = 1
        #expect(draft.graceDays == 3)
        draft.name = String(repeating: "x", count: 100)
        #expect(draft.name.count == 80)
    }

    @Test func changingKindDropsTheTagsWhichBelongToOneArr() {
        var draft = RuleDraft(kind: .movie)
        draft.toggle(tag: 3, with: true)
        draft.toggle(tag: 4, with: false)
        #expect(draft.has(tag: 3, with: true) && draft.has(tag: 4, with: false))
        #expect(draft.hasConditions)
        draft.setKind(.series)
        #expect(draft.withTags.isEmpty && draft.withoutTags.isEmpty)
        #expect(draft.kind == .series)
    }

    @Test func renamingDoesNotChangeWhatThePreviewAsks() {
        var a = RuleDraft()
        a.unmonitored = true
        var b = a
        b.name = "Old stuff"
        b.graceDays = 30
        #expect(a.probe == b.probe)
        b.setKind(.series)
        #expect(a.probe != b.probe)
    }

    @Test func aSavedRuleRoundTripsIntoTheBodyItCameFrom() {
        let rule = CleanupRule(
            conditions: .init(min_size_gb: 20, unmonitored: false, watched_days: 365, with_tags: [], without_tags: [7]),
            enabled: true, grace_days: 21, id: "abc", kind: .series, name: "Big and old"
        )
        let draft = RuleDraft(rule)
        #expect(draft.id == "abc" && draft.enabled && draft.kind == .series && draft.graceDays == 21)
        let input = draft.input
        #expect(input.id == "abc" && input.enabled == true && input.grace_days == 21 && input.kind == .series)
        #expect(input.conditions?.watched_days == 365)
        #expect(input.conditions?.min_size_gb == 20)
        #expect(input.conditions?.without_tags == [7])
        #expect(input.conditions?.unwatched_days == nil)
        #expect(draft.summary == "watched > 365 d · > 20 GB · tags")
        #expect(draft.title == "Big and old")
    }
}

@Suite struct CleanupConfirmationTests {
    let settings = CleanupRulesSettings(enabled: false, max_deletions: 10)

    @Test func anythingThatCanDeleteMoreAsksAndTurningThingsOffDoesNot() {
        let asks = { (change: CleanupRulesModel.Change) in CleanupRulesModel.asks(change, current: settings) }
        #expect(asks(.cleanup(on: true)))
        #expect(!asks(.cleanup(on: false)))
        #expect(asks(.rule(on: true)))
        #expect(!asks(.rule(on: false)))
        #expect(asks(.save(enabled: true)))
        #expect(!asks(.save(enabled: false)))
        #expect(asks(.limit(20)))
        #expect(!asks(.limit(5)))
        #expect(!asks(.limit(10)))
        #expect(asks(.delete))
        #expect(asks(.run(dry: false)))
        #expect(!asks(.run(dry: true)))
        #expect(asks(.unkeep))
        #expect(asks(.clearKept))
        #expect(!asks(.keep))
    }
}

@Suite struct CleanupWordsTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func countdownRoundsUpAndAPastDateIsTheNextRun() {
        let day = 86_400
        #expect(CleanupWords.countdown(1_000_000 + 3 * day - 60, now: now) == "Leaves in 3 days")
        #expect(CleanupWords.countdown(1_000_000 + 60, now: now) == "Leaves in 1 day")
        #expect(CleanupWords.countdown(1_000_000 - 60, now: now) == "Leaves at the next run")
    }

    @Test func reasonsAndHeldAreWorded() {
        #expect(CleanupWords.reason(.init(code: "unwatched", value: 162)) == "Never watched, added 162 days ago")
        #expect(CleanupWords.reason(.init(code: "rating", value: 4.25)).hasPrefix("Rated 4"))
        #expect(CleanupWords.reason(.init(code: "something_new")) == "something_new")
        #expect(CleanupWords.held([:]) == nil)
        #expect(CleanupWords.held(["requested": 1, "kept": 2]) == "2 kept, 1 requested")
    }

    @Test func aRunThatDidNothingSaysSo() {
        #expect(CleanupRun(trigger: "manual", ts: 1).didNothing)
        #expect(!CleanupRun(skipped: "disabled", trigger: "manual", ts: 1).didNothing)
        let run = CleanupRun(deleted: [.init(id: 1, kind: .movie)], marked: [.init(id: 2, kind: .movie), .init(id: 3, kind: .series)],
                             trigger: "schedule", ts: 1)
        #expect(run.groups.map(\.label) == ["Deleted (1)", "Marked (2)"])
    }
}

/// Keeps what is saved the way the server would, assigning ids to new rules.
actor FakeCleanupRules: CleanupRulesAPI {
    var stored: CleanupRules
    var previewFailure: CleanupRulesError?
    var runFailure: CleanupRulesError?
    var saveFailure: CleanupRulesError?
    private(set) var calls: [String] = []
    private(set) var savedBodies: [[RuleDraft]] = []
    private var nextID = 1

    init(rules: [CleanupRule] = [], enabled: Bool = false) {
        stored = CleanupRules(rules: rules, settings: .init(enabled: enabled, max_deletions: 10))
    }

    func fail(preview: CleanupRulesError? = nil, run: CleanupRulesError? = nil, save: CleanupRulesError? = nil) {
        previewFailure = preview
        runFailure = run
        saveFailure = save
    }

    func cleanupRules() async throws -> CleanupRules { stored }

    func saveCleanupRules(settings: CleanupRulesSettings, rules: [RuleDraft]) async throws -> CleanupRules {
        calls.append("put")
        if let saveFailure { throw saveFailure }
        savedBodies.append(rules)
        stored = CleanupRules(rules: rules.map { draft in
            var id = draft.id
            if id.isEmpty { id = "r\(nextID)"; nextID += 1 }
            return CleanupRule(conditions: draft.conditions, enabled: draft.enabled, grace_days: draft.graceDays, id: id,
                               kind: draft.kind == .movie ? .movie : .series, name: draft.name)
        }, settings: settings)
        return stored
    }

    func previewRule(_ draft: RuleDraft) async throws -> CleanupPreview {
        calls.append("preview")
        if let previewFailure { throw previewFailure }
        return CleanupPreview(held: .init(additionalProperties: ["kept": 1]),
                              matches: [.init(id: 5, kind: .movie, reasons: [.init(code: "unmonitored")], size: 100, title: "Heat")],
                              total_size: 100)
    }

    func leaving() async throws -> [CleanupLeaving] { calls.append("leaving"); return [] }
    func keep(_ kind: CleanupKind, id: Int, title: String, year: Int?) async throws { calls.append("keep \(kind.rawValue):\(id) \(title)") }
    func kept() async throws -> [CleanupKept] { calls.append("kept"); return [] }
    func unkeep(_ kind: CleanupKind, id: Int) async throws { calls.append("unkeep \(kind.rawValue):\(id)") }
    func clearKept() async throws { calls.append("clear") }
    func cleanupLog() async throws -> [CleanupRun] { calls.append("log"); return [] }

    func runCleanup(dryRun: Bool) async throws -> CleanupRun {
        calls.append(dryRun ? "dry" : "run")
        if let runFailure { throw runFailure }
        return CleanupRun(dry_run: dryRun, trigger: "manual", ts: 1)
    }

    func clearCalls() { calls = [] }
}

@Suite @MainActor struct CleanupRulesModelTests {
    let two: [CleanupRule] = [
        .init(conditions: .init(watched_days: 180), enabled: false, grace_days: 14, id: "a", kind: .movie, name: "Watched"),
        .init(conditions: .init(unmonitored: true), enabled: true, grace_days: 7, id: "b", kind: .series, name: "Unmonitored"),
    ]

    @Test func switchingOneRuleSendsTheWholeListWithOnlyThatOneChanged() async {
        let api = FakeCleanupRules(rules: two)
        let model = CleanupRulesModel(api: api)
        await model.load()
        await model.setRule("a", on: true)
        let body = await api.savedBodies.last ?? []
        #expect(body.map(\.id) == ["a", "b"])
        #expect(body.map(\.enabled) == [true, true])
        #expect(model.drafts.map(\.enabled) == [true, true])
    }

    @Test func aNewRuleIsAppendedAndGetsTheServersIdAndAnEditReplacesInPlace() async {
        let api = FakeCleanupRules(rules: two)
        let model = CleanupRulesModel(api: api)
        await model.load()
        var draft = RuleDraft(kind: .movie)
        draft.tick(.size, true)
        #expect(await model.save(draft))
        #expect(model.drafts.map(\.id) == ["a", "b", "r1"])
        #expect(model.drafts.last?.enabled == false, "saving never switches a rule on")

        var edit = model.drafts[1]
        edit.name = "Renamed"
        #expect(await model.save(edit))
        #expect(model.drafts.map(\.name) == ["Watched", "Renamed", ""])
        #expect(model.drafts[1].enabled, "an edit keeps the rule's own switch")
    }

    @Test func aRuleWithoutConditionsIsNotSaved() async {
        let api = FakeCleanupRules()
        let model = CleanupRulesModel(api: api)
        await model.load()
        #expect(await model.save(RuleDraft()) == false)
        #expect(await api.calls.contains("put") == false)
    }

    @Test func deletingRemovesOnlyThatRule() async {
        let api = FakeCleanupRules(rules: two)
        let model = CleanupRulesModel(api: api)
        await model.load()
        #expect(await model.delete("a"))
        #expect(model.drafts.map(\.id) == ["b"])
    }

    @Test func switchingOffReloadsLeavingSinceEverythingIsReleased() async {
        let api = FakeCleanupRules(rules: two, enabled: true)
        let model = CleanupRulesModel(api: api)
        await model.load()
        await api.clearCalls()
        await model.setCleanup(on: false)
        #expect(!model.enabled)
        #expect(await api.calls == ["put", "leaving", "log"])
        let body = await api.savedBodies.last ?? []
        #expect(body.count == 2, "the rules go along unchanged")
    }

    @Test func aRaisedLimitIsSavedAndOutOfRangeIsIgnored() async {
        let api = FakeCleanupRules(rules: two)
        let model = CleanupRulesModel(api: api)
        await model.load()
        await model.setLimit(20)
        #expect(model.maxDeletions == 20)
        await model.setLimit(500)
        #expect(model.maxDeletions == 20)
        #expect(model.limitChoices == [5, 10, 20, 50])
    }

    @Test func aFailedSaveKeepsWhatWasShownAndSaysWhy() async {
        let api = FakeCleanupRules(rules: two)
        let model = CleanupRulesModel(api: api)
        await model.load()
        await api.fail(save: .failed(500, "boom"))
        await model.setRule("a", on: true)
        #expect(model.drafts.map(\.enabled) == [false, true])
        #expect(model.error == "boom")
    }

    @Test func previewNeedsAConditionAndAnUnreachableServiceIsNotNoMatches() async {
        let api = FakeCleanupRules()
        let model = CleanupRulesModel(api: api)
        await model.updatePreview(RuleDraft())
        #expect(model.preview == .needsCondition)
        #expect(await api.calls.isEmpty)

        var draft = RuleDraft()
        draft.unmonitored = true
        await model.updatePreview(draft)
        guard case let .loaded(preview) = model.preview else { Issue.record("not loaded"); return }
        #expect(preview.matches?.map(\.id) == [5])
        #expect(CleanupWords.held(preview.held?.additionalProperties ?? [:]) == "1 kept")

        await api.fail(preview: .unreachable("Plex: unreachable"))
        await model.updatePreview(draft)
        #expect(model.preview == .failed("Could not ask every service: Plex: unreachable"))
    }

    @Test func aDryRunChangesNothingAndABusyRunIsReported() async {
        let api = FakeCleanupRules()
        let model = CleanupRulesModel(api: api)
        await model.run(dry: true)
        #expect(model.result?.dry_run == true)
        #expect(await api.calls == ["dry"], "a test run is not logged, so nothing reloads")

        await api.fail(run: .running)
        await model.run(dry: false)
        #expect(model.error == "A cleanup run is already going.")
    }

    @Test func keepingSendsTheTitleAndRefreshesBothLists() async {
        let api = FakeCleanupRules()
        let model = CleanupRulesModel(api: api)
        await model.keep(.movie, id: 5, title: "Heat", year: 1995)
        #expect(await api.calls == ["keep movie:5 Heat", "leaving", "kept"])
        await model.unkeep(CleanupKept(id: 5, kind: .movie, title: "Heat"))
        await model.clearKept()
        #expect(await api.calls.suffix(4) == ["unkeep movie:5", "kept", "clear", "kept"])
    }
}

@Suite struct CleanupRulesLiveTests {
    /// A real answer from the server's preview, trimmed to two matches.
    @Test func previewDecodes() async throws {
        let api = liveAPI(AnswerTransport(["/api/v1/cleanup/rules/preview": .init(body: """
        {"matches":[{"kind":"movie","id":143,"title":"Rogue One: A Star Wars Story","year":2016,"poster":"/api/v1/poster?u=x","size":40644555678,"reasons":[{"code":"unwatched","value":162.0}],"leave_at":null},
        {"kind":"movie","id":188,"title":"Michael","year":2026,"poster":null,"size":33685383362,"reasons":[{"code":"unwatched","value":34.0}],"leave_at":1791692676}],
        "total_size":74330000000,"held":{"recent":3}}
        """)]))
        var draft = RuleDraft()
        draft.tick(.unwatched, true)
        let preview = try await api.previewRule(draft)
        #expect(preview.matches?.count == 2)
        #expect(preview.matches?.last?.leave_at == 1_791_692_676)
        #expect(preview.held?.additionalProperties["recent"] == 3)
    }

    @Test func unreachableAndBusyComeBackAsTheirOwnErrors() async {
        let api = liveAPI(AnswerTransport([
            "/api/v1/cleanup/rules/preview": .init(status: 502, body: #"{"error":{"code":"service_unavailable","service":"plex","message":"timeout"}}"#),
            "/api/v1/cleanup/run": .init(status: 409, body: #"{"detail":"a cleanup run is already going"}"#),
        ]))
        var draft = RuleDraft()
        draft.unmonitored = true
        await #expect(throws: CleanupRulesError.unreachable("Plex: timeout")) { try await api.previewRule(draft) }
        await #expect(throws: CleanupRulesError.running) { try await api.runCleanup(dryRun: false) }
    }

    @Test func savingSendsTheSwitchAndEveryRule() async throws {
        let transport = AnswerTransport(["/api/v1/cleanup/rules": .init(body: #"{"settings":{"enabled":false,"max_deletions":10},"rules":[]}"#)])
        let api = liveAPI(transport)
        var a = RuleDraft(kind: .movie)
        a.tick(.watched, true)
        var b = RuleDraft(kind: .series)
        b.unmonitored = true
        _ = try await api.saveCleanupRules(settings: .init(enabled: false, max_deletions: 10), rules: [a, b])
        #expect(transport.requests == ["PUT /api/v1/cleanup/rules"])
        let body = try #require(transport.requestBodies.first?.data(using: .utf8))
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let rules = try #require(json["rules"] as? [[String: Any]])
        #expect(rules.count == 2)
        #expect((rules[0]["conditions"] as? [String: Any])?["watched_days"] as? Int == 180)
        #expect((rules[0]["conditions"] as? [String: Any])?["unwatched_days"] == nil, "an unticked condition is left out, not sent as 0")
        #expect((json["settings"] as? [String: Any])?["enabled"] as? Bool == false)
    }

    @Test func dryRunGoesAsAQueryFlag() async throws {
        let transport = AnswerTransport(["/api/v1/cleanup/run": .init(body: #"{"ts":1,"trigger":"manual","dry_run":true}"#)])
        let run = try await liveAPI(transport).runCleanup(dryRun: true)
        #expect(run.dry_run == true)
        #expect(transport.requests == ["POST /api/v1/cleanup/run?dry_run=true"])
    }
}
