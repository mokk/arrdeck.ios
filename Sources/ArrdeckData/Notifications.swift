import ArrdeckAPI
import Foundation
import Observation

public typealias PushEvents = Components.Schemas.PushEventsOut
public typealias PushRules = Components.Schemas.PushRulesOut

/// The server's notification settings: which events are pushed and the quiet
/// hours. This app cannot receive web push itself; these are the defaults
/// every browser subscribed to arrdeck follows.
public protocol NotificationsAPI: Sendable {
    func pushEvents() async throws -> PushEvents
    func savePushEvents(_ enabled: [String]) async throws -> PushEvents
    func pushRules() async throws -> PushRules
    /// `serviceDownMinutes` nil leaves the server's value as it is; send the
    /// one it last reported so a quiet-hours save does not reset it.
    func savePushRules(quietStart: String, quietEnd: String, timezone: String, tags: [String: [Int]],
                       digestDay: Int, digestTime: String, serviceDownMinutes: Int?) async throws -> PushRules
}

extension LiveAPI: NotificationsAPI {
    public func pushEvents() async throws -> PushEvents {
        try await call {
            switch try await client.push_events_api_v1_push_events_get(query: .init()) {
            case let .ok(ok): try ok.body.json
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func savePushEvents(_ enabled: [String]) async throws -> PushEvents {
        try await call {
            switch try await client.save_push_events_api_v1_push_events_put(body: .json(.init(enabled: enabled))) {
            case let .ok(ok): try ok.body.json
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func pushRules() async throws -> PushRules {
        try await call {
            switch try await client.push_rules_api_v1_push_rules_get() {
            case let .ok(ok): try ok.body.json
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func savePushRules(quietStart: String, quietEnd: String, timezone: String, tags: [String: [Int]],
                              digestDay: Int, digestTime: String, serviceDownMinutes: Int?) async throws -> PushRules {
        let body = Components.Schemas.PushRulesIn(
            digest_day: digestDay, digest_time: digestTime,
            quiet_end: quietEnd, quiet_start: quietStart,
            service_down_minutes: serviceDownMinutes,
            tags: .init(additionalProperties: tags), timezone: timezone
        )
        return try await call {
            switch try await client.save_push_rules_api_v1_push_rules_put(body: .json(body)) {
            case let .ok(ok): try ok.body.json
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }
}

@MainActor @Observable
public final class NotificationSettingsModel {
    public private(set) var events: Loadable<PushEvents> = .loading
    public private(set) var rules: PushRules?
    public var error: String?
    private let api: any NotificationsAPI

    public init(api: any NotificationsAPI) { self.api = api }

    public var enabled: Set<String> { Set(events.value?.enabled ?? []) }

    public func load() async {
        do {
            async let e = api.pushEvents()
            async let r = api.pushRules()
            events = .loaded(try await e)
            rules = try await r
        } catch {
            events = .failed((error as? APIError)?.description ?? error.localizedDescription)
        }
    }

    public func set(_ key: String, on: Bool) async {
        var next = enabled
        if on { next.insert(key) } else { next.remove(key) }
        let order = (events.value?.available ?? []).map(\.key).filter(next.contains)
        do { events = .loaded(try await api.savePushEvents(order)) } catch { self.error = error.localizedDescription }
    }

    /// Quiet hours as "HH:MM"; empty strings switch them off.
    public func setQuiet(start: String, end: String) async {
        await save(start: start, end: end, day: digestDay, time: digestTime)
    }

    /// Monday = 0, as on the server.
    public var digestDay: Int { rules?.digest_day ?? 6 }
    public var digestTime: String { rules?.digest_time ?? "18:00" }

    /// When the weekly digest goes out, "HH:MM" in this device's time zone.
    public func setDigest(day: Int, time: String) async {
        await save(start: rules?.quiet_start ?? "", end: rules?.quiet_end ?? "", day: day, time: time)
    }

    /// Whether this server pushes service alerts at all; older ones neither
    /// list the events nor keep the delay.
    public var hasServiceAlerts: Bool {
        (events.value?.available ?? []).contains { $0.key == "service_down" || $0.key == "service_up" }
    }

    public static let serviceDownRange = 1...120

    /// How long a service has to stay silent before "service down" is pushed.
    public var serviceDownMinutes: Int { rules?.service_down_minutes ?? 10 }

    public func setServiceDownMinutes(_ minutes: Int) async {
        let clamped = min(max(minutes, Self.serviceDownRange.lowerBound), Self.serviceDownRange.upperBound)
        guard clamped != rules?.service_down_minutes else { return }
        await save(start: rules?.quiet_start ?? "", end: rules?.quiet_end ?? "", day: digestDay, time: digestTime,
                   downMinutes: clamped)
    }

    private func save(start: String, end: String, day: Int, time: String, downMinutes: Int? = nil) async {
        do {
            rules = try await api.savePushRules(
                quietStart: start, quietEnd: end,
                timezone: TimeZone.current.identifier,
                tags: rules?.tags?.additionalProperties ?? [:],
                digestDay: day, digestTime: time,
                serviceDownMinutes: downMinutes ?? rules?.service_down_minutes
            )
        } catch { self.error = error.localizedDescription }
    }
}
