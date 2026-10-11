import ArrdeckAPI
import Foundation
import Observation

public typealias CleanupRules = Components.Schemas.CleanupRulesOut
public typealias CleanupRule = Components.Schemas.CleanupRuleOut
public typealias CleanupRulesSettings = Components.Schemas.CleanupRulesSettings
public typealias CleanupConditions = Components.Schemas.CleanupConditions
public typealias CleanupPreview = Components.Schemas.CleanupPreviewOut
public typealias CleanupMatch = Components.Schemas.CleanupMatchOut
public typealias CleanupReason = Components.Schemas.CleanupReasonOut
public typealias CleanupLeaving = Components.Schemas.CleanupLeavingOut
public typealias CleanupKept = Components.Schemas.CleanupKeptOut
public typealias CleanupRun = Components.Schemas.CleanupRunOut
public typealias CleanupLogTitle = Components.Schemas.CleanupLogTitleOut

/// What a rule looks at: films through Radarr or shows through Sonarr.
public enum CleanupKind: String, CaseIterable, Sendable, Hashable {
    case movie, series

    public var label: String {
        switch self {
        case .movie: String(localized: "Films")
        case .series: String(localized: "Shows")
        }
    }

    /// Whose tags a rule's tag conditions name.
    public var app: ArrApp { self == .movie ? .radarr : .sonarr }
}

/// Why a cleanup call did not do what it was asked, in words for the screen.
public enum CleanupRulesError: Error, Equatable, Sendable, CustomStringConvertible {
    /// 502: Plex, an arr or Overseerr did not answer, so there is no honest
    /// answer — never to be shown as "nothing matches".
    case unreachable(String?)
    /// 409: a run is already going.
    case running
    case failed(Int, String?)

    public var description: String {
        switch self {
        case let .unreachable(message):
            message.map { String(localized: "Could not ask every service: \($0)") }
                ?? String(localized: "Could not ask every service.")
        case .running: String(localized: "A cleanup run is already going.")
        case let .failed(code, message): message ?? "HTTP \(code)"
        }
    }

    static func from(_ code: Int, _ message: String?) -> any Error {
        switch code {
        case 401: APIError.unauthorized
        case 409: CleanupRulesError.running
        case 502: CleanupRulesError.unreachable(message)
        default: CleanupRulesError.failed(code, message)
        }
    }
}

/// Rule-based cleanup: the switch and rules, their preview, what is leaving
/// soon, the keep list, the run log and a run on demand.
public protocol CleanupRulesAPI: Sendable {
    func cleanupRules() async throws -> CleanupRules
    /// Replaces the switch and the whole list; the server gives new rules their id.
    func saveCleanupRules(settings: CleanupRulesSettings, rules: [RuleDraft]) async throws -> CleanupRules
    /// What the rule, saved or not, on or off, would take right now. Read-only.
    func previewRule(_ draft: RuleDraft) async throws -> CleanupPreview
    func leaving() async throws -> [CleanupLeaving]
    /// Off the leaving list and the Plex collection, and never matched again
    /// until taken off the keep list. Works for a title not leaving yet.
    func keep(_ kind: CleanupKind, id: Int, title: String, year: Int?) async throws
    func kept() async throws -> [CleanupKept]
    func unkeep(_ kind: CleanupKind, id: Int) async throws
    func clearKept() async throws
    func cleanupLog() async throws -> [CleanupRun]
    func runCleanup(dryRun: Bool) async throws -> CleanupRun
}

extension LiveAPI: CleanupRulesAPI {
    public func cleanupRules() async throws -> CleanupRules {
        try await call {
            switch try await client.get_rules_api_v1_cleanup_rules_get() {
            case let .ok(ok): try ok.body.json
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func saveCleanupRules(settings: CleanupRulesSettings, rules: [RuleDraft]) async throws -> CleanupRules {
        let body = Components.Schemas.CleanupRulesIn(rules: rules.map(\.input), settings: settings)
        // Undocumented statuses are thrown outside `call`, which would turn
        // them into transport failures and lose what the server said.
        let output = try await call { try await client.put_rules_api_v1_cleanup_rules_put(body: .json(body)) }
        switch output {
        case let .ok(ok): return try await call { try ok.body.json }
        case .unprocessableContent: throw APIError.unexpectedStatus(422)
        case let .undocumented(code, payload): throw CleanupRulesError.from(code, await ServerMessage.read(payload))
        }
    }

    public func previewRule(_ draft: RuleDraft) async throws -> CleanupPreview {
        let output = try await call {
            try await client.preview_rule_api_v1_cleanup_rules_preview_post(body: .json(draft.input))
        }
        switch output {
        case let .ok(ok): return try await call { try ok.body.json }
        case .unprocessableContent: throw APIError.unexpectedStatus(422)
        case let .undocumented(code, payload): throw CleanupRulesError.from(code, await ServerMessage.read(payload))
        }
    }

    public func leaving() async throws -> [CleanupLeaving] {
        try await call {
            switch try await client.leaving_api_v1_cleanup_leaving_get() {
            case let .ok(ok): try ok.body.json
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func keep(_ kind: CleanupKind, id: Int, title: String, year: Int?) async throws {
        let output = try await call {
            try await client.keep_api_v1_cleanup_leaving__kind___item_id__keep_post(
                path: .init(kind: kind.rawValue, item_id: id), body: .json(.init(title: String(title.prefix(300)), year: year))
            )
        }
        switch output {
        case .ok: ()
        case .unprocessableContent: throw APIError.unexpectedStatus(422)
        case let .undocumented(code, payload): throw CleanupRulesError.from(code, await ServerMessage.read(payload))
        }
    }

    public func kept() async throws -> [CleanupKept] {
        try await call {
            switch try await client.kept_api_v1_cleanup_kept_get() {
            case let .ok(ok): try ok.body.json
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func unkeep(_ kind: CleanupKind, id: Int) async throws {
        try await call {
            switch try await client.unkeep_api_v1_cleanup_kept__kind___item_id__delete(
                path: .init(kind: kind.rawValue, item_id: id)
            ) {
            case .noContent: ()
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func clearKept() async throws {
        try await call {
            switch try await client.clear_kept_api_v1_cleanup_kept_delete() {
            case .noContent: ()
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func cleanupLog() async throws -> [CleanupRun] {
        try await call {
            switch try await client.run_log_api_v1_cleanup_log_get() {
            case let .ok(ok): try ok.body.json
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func runCleanup(dryRun: Bool) async throws -> CleanupRun {
        let output = try await call { try await client.run_now_api_v1_cleanup_run_post(query: .init(dry_run: dryRun)) }
        switch output {
        case let .ok(ok): return try await call { try ok.body.json }
        case .unprocessableContent: throw APIError.unexpectedStatus(422)
        case let .undocumented(code, payload): throw CleanupRulesError.from(code, await ServerMessage.read(payload))
        }
    }
}

/// One rule as the editor holds it. Conditions that are nil are not ticked;
/// a title must meet every ticked one. Values stay inside the server's
/// bounds, so neither the preview nor the save can be refused for them.
public struct RuleDraft: Sendable, Equatable, Hashable {
    /// The numeric conditions, with where a freshly ticked one starts and
    /// the values the editor offers.
    public enum Number: String, CaseIterable, Sendable {
        case watched, unwatched, size, rating

        public var label: String {
            switch self {
            case .watched: String(localized: "Watched, last played more than")
            case .unwatched: String(localized: "Never watched, added more than")
            case .size: String(localized: "Larger than")
            case .rating: String(localized: "Rating below")
            }
        }

        public var start: Double {
            switch self {
            case .watched: 180
            case .unwatched: 365
            case .size: 50
            case .rating: 5
            }
        }

        public var choices: [Double] {
            switch self {
            case .watched, .unwatched: [14, 30, 60, 90, 180, 365, 730, 1095]
            case .size: [1, 2, 5, 10, 20, 50, 100]
            case .rating: [3, 4, 5, 5.5, 6, 6.5, 7]
            }
        }

        /// The server's bounds: whole days 1…3650, size above 0, rating in (0, 10].
        func clamp(_ value: Double) -> Double {
            switch self {
            case .watched, .unwatched: min(max(value.rounded(), 1), 3650)
            case .size: min(max(value, 0.1), 100_000)
            case .rating: min(max(value, 0.1), 10)
            }
        }

        public func format(_ value: Double) -> String {
            switch self {
            case .watched, .unwatched: String(localized: "\(Int(value)) days")
            case .size: "\(value.formatted(.number.precision(.fractionLength(0...1)))) GB"
            case .rating: value.formatted(.number.precision(.fractionLength(0...1)))
            }
        }
    }

    public static let graceRange = 3...365
    public static let graceChoices = [3, 7, 14, 21, 30, 60, 90]
    public static let nameLimit = 80
    public static let maxRules = 30

    public var id: String
    public var name: String {
        didSet { if name.count > Self.nameLimit { name = String(name.prefix(Self.nameLimit)) } }
    }
    /// Use `setKind`, which also drops the tags.
    public private(set) var kind: CleanupKind
    public var enabled: Bool
    public var graceDays: Int {
        didSet { graceDays = min(max(graceDays, Self.graceRange.lowerBound), Self.graceRange.upperBound) }
    }
    public private(set) var watchedDays: Int?
    public private(set) var unwatchedDays: Int?
    public private(set) var minSizeGB: Double?
    public private(set) var ratingBelow: Double?
    public var unmonitored: Bool
    public private(set) var withTags: [Int]
    public private(set) var withoutTags: [Int]

    /// A new rule: off, the server's default grace period, nothing ticked.
    public init(kind: CleanupKind = .movie) {
        id = ""
        name = ""
        self.kind = kind
        enabled = false
        graceDays = 14
        unmonitored = false
        withTags = []
        withoutTags = []
    }

    public init(_ rule: CleanupRule) {
        id = rule.id
        name = rule.name
        kind = rule.kind == .movie ? .movie : .series
        enabled = rule.enabled
        graceDays = rule.grace_days
        let c = rule.conditions
        watchedDays = c.watched_days
        unwatchedDays = c.unwatched_days
        minSizeGB = c.min_size_gb
        ratingBelow = c.rating_below
        unmonitored = c.unmonitored ?? false
        withTags = c.with_tags ?? []
        withoutTags = c.without_tags ?? []
    }

    public var isNew: Bool { id.isEmpty }

    public func value(_ number: Number) -> Double? {
        switch number {
        case .watched: watchedDays.map(Double.init)
        case .unwatched: unwatchedDays.map(Double.init)
        case .size: minSizeGB
        case .rating: ratingBelow
        }
    }

    /// nil unticks the condition.
    public mutating func set(_ number: Number, _ value: Double?) {
        let clamped = value.map(number.clamp)
        switch number {
        case .watched: watchedDays = clamped.map { Int($0) }
        case .unwatched: unwatchedDays = clamped.map { Int($0) }
        case .size: minSizeGB = clamped
        case .rating: ratingBelow = clamped
        }
    }

    public mutating func tick(_ number: Number, _ on: Bool) {
        set(number, on ? (value(number) ?? number.start) : nil)
    }

    /// Tag ids belong to one arr, so they do not survive a change of kind.
    public mutating func setKind(_ kind: CleanupKind) {
        guard kind != self.kind else { return }
        self.kind = kind
        withTags = []
        withoutTags = []
    }

    public func has(tag: Int, with: Bool) -> Bool {
        (with ? withTags : withoutTags).contains(tag)
    }

    public mutating func toggle(tag: Int, with: Bool) {
        if with {
            if let index = withTags.firstIndex(of: tag) { withTags.remove(at: index) } else { withTags.append(tag) }
        } else {
            if let index = withoutTags.firstIndex(of: tag) { withoutTags.remove(at: index) } else { withoutTags.append(tag) }
        }
    }

    /// The server matches nothing with a rule that has no condition; the
    /// editor says so instead of showing an empty preview as a result.
    public var hasConditions: Bool {
        watchedDays != nil || unwatchedDays != nil || minSizeGB != nil || ratingBelow != nil
            || unmonitored || !withTags.isEmpty || !withoutTags.isEmpty
    }

    public var canSave: Bool { hasConditions && Self.graceRange.contains(graceDays) }

    /// Only what decides the matches, so renaming a rule does not ask Plex again.
    public var probe: RuleDraft? {
        guard hasConditions else { return nil }
        var probe = self
        probe.id = ""
        probe.name = ""
        probe.enabled = false
        probe.graceDays = 14
        return probe
    }

    public var conditions: CleanupConditions {
        CleanupConditions(
            min_size_gb: minSizeGB, rating_below: ratingBelow, unmonitored: unmonitored,
            unwatched_days: unwatchedDays, watched_days: watchedDays,
            with_tags: withTags, without_tags: withoutTags
        )
    }

    public var input: Components.Schemas.CleanupRuleIn {
        .init(
            conditions: conditions, enabled: enabled, grace_days: graceDays, id: id,
            kind: kind == .movie ? .movie : .series, name: name
        )
    }

    /// The conditions in a line: "watched > 180 d · > 50 GB".
    public var summary: String {
        var parts: [String] = []
        if let watchedDays { parts.append(String(localized: "watched > \(watchedDays) d")) }
        if let unwatchedDays { parts.append(String(localized: "unwatched > \(unwatchedDays) d")) }
        if let minSizeGB { parts.append(String(localized: "> \(Number.size.format(minSizeGB))")) }
        if let ratingBelow { parts.append(String(localized: "rating < \(Number.rating.format(ratingBelow))")) }
        if unmonitored { parts.append(String(localized: "unmonitored")) }
        if !withTags.isEmpty || !withoutTags.isEmpty { parts.append(String(localized: "tags")) }
        return parts.isEmpty ? String(localized: "no conditions") : parts.joined(separator: " · ")
    }

    /// Its name, or what it does when it has none.
    public var title: String { name.trimmingCharacters(in: .whitespaces).isEmpty ? summary : name }
}

/// The wording of the server's codes, shared by the preview, Leaving soon and the log.
public enum CleanupWords {
    public static func reason(_ reason: CleanupReason) -> String {
        let value = reason.value ?? 0
        switch reason.code {
        case "watched": return String(localized: "Last watched \(Int(value)) days ago")
        case "unwatched": return String(localized: "Never watched, added \(Int(value)) days ago")
        case "size": return Format.bytes(Int(value))
        case "rating": return String(localized: "Rated \(value.formatted(.number.precision(.fractionLength(1))))")
        case "unmonitored": return String(localized: "Unmonitored")
        case "without_tags": return String(localized: "Without the tags")
        case "with_tags": return String(localized: "Tagged")
        default: return reason.code
        }
    }

    /// Whole days until a leaving title's date; 0 or less means the next run.
    public static func daysLeft(_ leaveAt: Int, now: Date = .now) -> Int {
        Int(((Double(leaveAt) - now.timeIntervalSince1970) / 86_400).rounded(.up))
    }

    public static func countdown(_ leaveAt: Int, now: Date = .now) -> String {
        let days = daysLeft(leaveAt, now: now)
        if days <= 0 { return String(localized: "Leaves at the next run") }
        return days == 1 ? String(localized: "Leaves in 1 day") : String(localized: "Leaves in \(days) days")
    }

    /// Why the preview left titles out: "2 kept, 1 requested".
    public static func held(_ held: [String: Int]) -> String? {
        let parts = ["kept", "requested", "recent"].compactMap { key -> String? in
            guard let n = held[key], n > 0 else { return nil }
            return switch key {
            case "kept": String(localized: "\(n) kept")
            case "requested": String(localized: "\(n) requested")
            default: String(localized: "\(n) added recently")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    public static func trigger(_ trigger: String) -> String {
        switch trigger {
        case "schedule": String(localized: "Daily")
        case "manual": String(localized: "Run now")
        case "switch": String(localized: "Switched off")
        default: trigger
        }
    }

    public static func skipped(_ skipped: String) -> String {
        switch skipped {
        case "disabled": String(localized: "Skipped: automatic cleanup is off")
        case "unreachable": String(localized: "Skipped: a service could not be reached")
        default: String(localized: "Skipped: \(skipped)")
        }
    }

    /// Why a title stopped leaving.
    public static func released(_ reason: String) -> String {
        switch reason {
        case "kept": String(localized: "kept")
        case "rule_off": String(localized: "rule off or deleted")
        case "gone": String(localized: "no longer in the library")
        case "no_match": String(localized: "no longer matches")
        case "requested": String(localized: "requested")
        case "recent": String(localized: "added recently")
        case "switched_off": String(localized: "automatic cleanup switched off")
        default: reason
        }
    }
}

extension CleanupRun {
    /// The run's titles by what happened to them, deletions first; empty
    /// groups are left out.
    public var groups: [(label: String, items: [CleanupLogTitle])] {
        [
            (String(localized: "Deleted (\((deleted ?? []).count))"), deleted ?? []),
            (String(localized: "Marked (\((marked ?? []).count))"), marked ?? []),
            (String(localized: "Released (\((released ?? []).count))"), released ?? []),
            (String(localized: "Kept (\((kept ?? []).count))"), kept ?? []),
        ].filter { !$0.1.isEmpty }
    }

    public var didNothing: Bool { skipped == nil && groups.isEmpty && (deferred ?? 0) == 0 && (errors ?? []).isEmpty }
}

extension CleanupLeaving {
    public var key: String { "\(kind.rawValue):\(id)" }
    public var cleanupKind: CleanupKind { kind == .movie ? .movie : .series }
    public var ref: MediaRef { kind == .movie ? .movie(id) : .series(id) }
}

extension CleanupMatch {
    public var key: String { "\(kind.rawValue):\(id)" }
    public var cleanupKind: CleanupKind { kind == .movie ? .movie : .series }
}

extension CleanupKept {
    public var key: String { "\(kind.rawValue):\(id)" }
    public var cleanupKind: CleanupKind { kind == .movie ? .movie : .series }
    public var label: String { (title ?? "").isEmpty ? "#\(id)" : title ?? "" }
}
