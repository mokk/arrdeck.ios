import ArrdeckAPI
import Foundation
import Observation

public typealias ActivitySince = Components.Schemas.ActivitySinceOut
public typealias ActivityEvent = Components.Schemas.ActivityEventOut

public protocol ActivityAPI: Sendable {
    func activitySince(_ since: Date) async throws -> ActivitySince
}

extension LiveAPI: ActivityAPI {
    public func activitySince(_ since: Date) async throws -> ActivitySince {
        try await call {
            switch try await client.activity_since_api_v1_activity_since_get(
                query: .init(since: since.formatted(.iso8601))
            ) {
            case let .ok(ok): try ok.body.json
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }
}

/// What happened since the Activity tab was last opened. Polled for the badge
/// on the tab; History marks what is newer than the mark and moves it once
/// it has been shown.
@MainActor @Observable
public final class ActivityFeedModel {
    public private(set) var lastSeen: Date
    public private(set) var feed: Loadable<ActivitySince>?
    public var count: Int { feed?.value?.count ?? 0 }
    public var items: [ActivityEvent] { feed?.value?.items ?? [] }

    private let api: any ActivityAPI
    private let defaults: UserDefaults
    private let cadence: Cadence
    private let onSessionLost: @MainActor () -> Void
    private static let key = "activity.lastSeen"

    public init(api: any ActivityAPI, defaults: UserDefaults = .standard, cadence: Cadence = .standard,
                onSessionLost: @escaping @MainActor () -> Void) {
        self.api = api
        self.defaults = defaults
        self.cadence = cadence
        self.onSessionLost = onSessionLost
        if let stored = defaults.object(forKey: Self.key) as? Date {
            lastSeen = stored
        } else {
            // a fresh install badges the last day, not everything the arrs remember
            lastSeen = Date.now.addingTimeInterval(-24 * 3600)
            defaults.set(lastSeen, forKey: Self.key)
        }
    }

    public func refresh() async {
        if feed == nil { feed = .loading }
        do {
            feed = .loaded(try await api.activitySince(lastSeen))
        } catch APIError.unauthorized {
            onSessionLost()
        } catch {
            if feed?.value == nil { feed = .failed((error as? APIError)?.description ?? error.localizedDescription) }
        }
    }

    /// Polls until cancelled — the tab bar's badge.
    public func run() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(cadence.recent))
        }
    }

    /// History has been shown: whatever it listed is no longer new, so the
    /// badge clears now and the next poll counts from here.
    public func markSeen(at date: Date) {
        guard date > lastSeen else { return }
        lastSeen = date
        defaults.set(date, forKey: Self.key)
        feed = .loaded(ActivitySince(count: 0, items: [], now: date.formatted(.iso8601), since: date.formatted(.iso8601)))
    }
}
