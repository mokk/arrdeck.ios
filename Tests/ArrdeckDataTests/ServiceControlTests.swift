import ArrdeckAPI
import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing
@testable import ArrdeckData

/// One canned answer per path, with headers, recording each request's method
/// and path — StubTransport has no way to send Retry-After.
final class AnswerTransport: ClientTransport, @unchecked Sendable {
    struct Answer: Sendable {
        var status = 200
        var body = ""
        var headers: [String: String] = [:]
    }

    private let answers: [String: Answer]
    private let lock = NSLock()
    private var sent: [String] = []
    private var bodies: [String] = []

    init(_ answers: [String: Answer]) { self.answers = answers }

    var requests: [String] { lock.withLock { sent } }
    var requestBodies: [String] { lock.withLock { bodies } }

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let full = request.path ?? ""
        let path = full.split(separator: "?").first.map(String.init) ?? ""
        var text = ""
        if let body { text = String(decoding: try await Data(collecting: body, upTo: 1 << 20), as: UTF8.self) }
        lock.withLock {
            sent.append("\(request.method.rawValue) \(full)")
            bodies.append(text)
        }
        let answer = answers[path] ?? Answer(status: 404, body: #"{"detail":"no stub"}"#)
        var response = HTTPResponse(status: .init(code: answer.status))
        response.headerFields[.contentType] = "application/json"
        for (name, value) in answer.headers {
            if let field = HTTPField.Name(name) { response.headerFields[field] = value }
        }
        return (response, answer.body.isEmpty ? nil : HTTPBody(answer.body))
    }
}

func liveAPI(_ transport: AnswerTransport) -> LiveAPI {
    LiveAPI(router: AddressRouter(primary: URL(string: "http://stub")!), transport: transport)
}

@Suite struct ServiceStatusDecodingTests {
    /// The backend stamps down_since itself, with microseconds; the arrs'
    /// dates have none. Both have to decode or the whole list fails.
    @Test func downSinceDecodesWithAndWithoutFractionalSeconds() async throws {
        let api = liveAPI(AnswerTransport(["/api/v1/status": .init(body: """
        [{"service":"radarr","ok":false,"error":"timeout","down_since":"2026-10-11T04:24:36.123456Z"},
         {"service":"sonarr","ok":false,"down_since":"2026-10-11T04:20:00Z"},
         {"service":"plex","ok":true,"down_since":null}]
        """)]))
        let rows = try await api.status()
        #expect(rows.count == 3)
        let radarr = try #require(rows[0].down_since)
        #expect(abs(radarr.timeIntervalSince1970 - 1_791_692_676.123) < 0.01)
        #expect(rows[1].down_since != nil)
        #expect(rows[2].down_since == nil)
    }

    @Test func downForReadsAsMinutesThenHours() throws {
        let since = Date(timeIntervalSince1970: 1_000_000)
        let status = ServiceStatus(down_since: since, ok: false, service: .radarr)
        #expect(status.downFor(now: since.addingTimeInterval(14 * 60)) == "down 14m")
        #expect(status.downFor(now: since.addingTimeInterval(2 * 3600 + 5 * 60)) == "down 2h 5m")
        #expect(ServiceStatus(ok: true, service: .plex).downFor() == nil)
    }
}

@Suite struct ServiceActionTests {
    let path = "/api/v1/system/services/radarr/restart"

    @Test func restartAnswersAndSelfIsPending() async throws {
        let transport = AnswerTransport([
            path: .init(body: #"{"project":"radarr","action":"restart"}"#),
            "/api/v1/system/services/arrdeck/restart": .init(body: #"{"project":"arrdeck","action":"restart","pending":true}"#),
        ])
        let api = liveAPI(transport)
        #expect(try await api.serviceAction("radarr", .restart) == false)
        #expect(try await api.serviceAction("arrdeck", .restart) == true)
        #expect(transport.requests == ["POST /api/v1/system/services/radarr/restart", "POST /api/v1/system/services/arrdeck/restart"])
    }

    @Test func helperStatesBecomeTheirOwnErrors() async {
        let missing = liveAPI(AnswerTransport([path: .init(status: 409, body: #"{"detail":"the host helper is not configured"}"#)]))
        await #expect(throws: ServiceActionError.notConfigured) { try await missing.serviceAction("radarr", .restart) }

        let soon = liveAPI(AnswerTransport([path: .init(status: 429, body: #"{"detail":"too soon"}"#, headers: ["Retry-After": "42"])]))
        await #expect(throws: ServiceActionError.tooSoon(retryAfter: 42)) { try await soon.serviceAction("radarr", .restart) }

        let down = liveAPI(AnswerTransport([path: .init(status: 502, body: #"{"error":{"code":"service_unavailable","service":"helper","message":"connection refused"}}"#)]))
        await #expect(throws: ServiceActionError.unreachable("helper: connection refused")) { try await down.serviceAction("radarr", .restart) }
    }

    @Test func aStoppedProjectIsStartedNotRestarted() {
        #expect(RestartableProject(name: "radarr", running: false).action == .up)
        #expect(RestartableProject(name: "radarr", running: true).action == .restart)
    }
}

actor FakeServiceControl: ServiceControlAPI {
    var answer: Restartable
    var failure: ServiceActionError?
    var pending = false
    private(set) var actions: [String] = []

    init(_ answer: Restartable) { self.answer = answer }

    func set(failure: ServiceActionError?) { self.failure = failure }
    func set(pending: Bool) { self.pending = pending }

    func restartable() async throws -> Restartable { answer }

    func serviceAction(_ project: String, _ action: ServiceAction) async throws -> Bool {
        actions.append("\(action.rawValue) \(project)")
        if let failure { throw failure }
        return pending
    }
}

@Suite @MainActor struct ServiceControlModelTests {
    let projects: [RestartableProject] = [
        .init(containers: 1, name: "radarr", running: true, running_containers: 1, service: "radarr"),
        .init(containers: 2, name: "media-vpn", running: false, running_containers: 0),
        .init(containers: 1, is_self: true, name: "arrdeck", running: true, running_containers: 1),
    ]

    @Test func notConfiguredAndUnreachableAreStatesNotErrors() async {
        let off = ServiceControlModel(api: FakeServiceControl(.init(configured: false)))
        await off.load()
        #expect(off.helper == .notConfigured)
        #expect(off.error == nil)

        let away = ServiceControlModel(api: FakeServiceControl(.init(configured: true, error: "connection refused")))
        await away.load()
        #expect(away.helper == .unreachable("connection refused"))
        #expect(away.projects.isEmpty)
    }

    @Test func projectsJoinStatusRowsByServiceAndTheRestListAfter() async {
        let model = ServiceControlModel(api: FakeServiceControl(.init(configured: true, projects: projects)))
        await model.load()
        #expect(model.project(for: "radarr")?.name == "radarr")
        #expect(model.project(for: "sonarr") == nil)
        #expect(model.unmatched(services: ["radarr", "sonarr"]).map(\.name) == ["media-vpn", "arrdeck"])
    }

    @Test func actingRestartsOrStartsAndSaysSo() async {
        let api = FakeServiceControl(.init(configured: true, projects: projects))
        let model = ServiceControlModel(api: api)
        await model.load()
        #expect(await model.act(projects[0]))
        #expect(model.note == "Radarr restarted")
        #expect(await model.act(projects[1]))
        #expect(model.note == "media-vpn started")
        #expect(await api.actions == ["restart radarr", "up media-vpn"])
        #expect(model.working.isEmpty)
    }

    @Test func restartingArrdeckWarnsItGoesAway() async {
        let api = FakeServiceControl(.init(configured: true, projects: projects))
        await api.set(pending: true)
        let model = ServiceControlModel(api: api)
        await model.load()
        #expect(await model.act(projects[2]))
        #expect(model.note == "arrdeck is restarting — back in a moment")
    }

    @Test func aMissingHelperOnRestartTurnsIntoTheNote() async {
        let api = FakeServiceControl(.init(configured: true, projects: projects))
        let model = ServiceControlModel(api: api)
        await model.load()
        await api.set(failure: .notConfigured)
        #expect(await model.act(projects[0]) == false)
        #expect(model.helper == .notConfigured)
        #expect(model.error == "The host helper is not set up.")
    }
}

actor FakeNotifications: NotificationsAPI {
    var rules: PushRules
    private(set) var saved: [Int?] = []

    init(rules: PushRules) { self.rules = rules }

    func pushEvents() async throws -> PushEvents {
        PushEvents(available: [.init(key: "service_down", label: "Service down"), .init(key: "service_up", label: "Service back up")],
                   enabled: ["service_down"])
    }
    func savePushEvents(_ enabled: [String]) async throws -> PushEvents { try await pushEvents() }
    func pushRules() async throws -> PushRules { rules }
    func savePushRules(quietStart: String, quietEnd: String, timezone: String, tags: [String: [Int]],
                       digestDay: Int, digestTime: String, serviceDownMinutes: Int?) async throws -> PushRules {
        saved.append(serviceDownMinutes)
        rules.quiet_start = quietStart
        rules.quiet_end = quietEnd
        if let serviceDownMinutes { rules.service_down_minutes = serviceDownMinutes }
        return rules
    }
}

@Suite @MainActor struct ServiceAlertSettingsTests {
    @Test func otherSavesSendTheDelayTheServerHas() async {
        let api = FakeNotifications(rules: PushRules(service_down_minutes: 25))
        let model = NotificationSettingsModel(api: api)
        await model.load()
        #expect(model.hasServiceAlerts)
        await model.setQuiet(start: "22:00", end: "07:00")
        await model.setDigest(day: 2, time: "09:00")
        #expect(await api.saved == [25, 25], "a quiet-hours or digest save must not reset the delay")
    }

    @Test func theDelayIsClampedAndUnchangedValuesAreNotSaved() async {
        let api = FakeNotifications(rules: PushRules(service_down_minutes: 10))
        let model = NotificationSettingsModel(api: api)
        await model.load()
        await model.setServiceDownMinutes(10)
        await model.setServiceDownMinutes(500)
        await model.setServiceDownMinutes(0)
        #expect(await api.saved == [120, 1])
        #expect(model.serviceDownMinutes == 1)
    }
}
