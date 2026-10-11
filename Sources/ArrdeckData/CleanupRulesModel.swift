import Foundation
import Observation

/// Cleanup → Rules: the switch, the rules, Leaving soon, the keep list and
/// the run log, and which changes have to be confirmed first. Everything that
/// switches deleting on, lets it delete more, or deletes now asks; turning
/// things off, keeping a title and a test run do not.
@MainActor @Observable
public final class CleanupRulesModel {
    /// A change the screen is about to make, for deciding whether it asks first.
    public enum Change: Equatable, Sendable {
        /// The global switch.
        case cleanup(on: Bool)
        /// Deletions per run.
        case limit(Int)
        /// One rule's own switch.
        case rule(on: Bool)
        /// Saving the editor; an enabled rule's change applies from the next run.
        case save(enabled: Bool)
        case delete
        case run(dry: Bool)
        /// Off the keep list, one title or all of them: the rules may match them again.
        case unkeep
        case clearKept
        case keep
    }

    public enum Preview: Equatable, Sendable {
        case idle
        /// No condition ticked: the server would match nothing.
        case needsCondition
        case loading
        case loaded(CleanupPreview)
        /// Including a service that could not be asked — never "no matches".
        case failed(String)
    }

    public static let limitChoices = [5, 10, 20, 50]

    public private(set) var rules: Loadable<CleanupRules> = .loading
    public private(set) var leaving: Loadable<[CleanupLeaving]> = .loading
    public private(set) var kept: Loadable<[CleanupKept]> = .loading
    public private(set) var log: Loadable<[CleanupRun]> = .loading
    public private(set) var preview: Preview = .idle
    public private(set) var saving = false
    public private(set) var running = false
    /// Titles with a keep or unkeep in flight, by key.
    public private(set) var keeping: Set<String> = []
    /// The answer to the last run or test run, for its sheet.
    public var result: CleanupRun?
    public var error: String?

    private let api: any CleanupRulesAPI
    private var previewGeneration = 0

    public init(api: any CleanupRulesAPI) { self.api = api }

    /// Whether `change` asks before it is made. Pure, so it is tested without a screen.
    public nonisolated static func asks(_ change: Change, current: CleanupRulesSettings?) -> Bool {
        switch change {
        case let .cleanup(on): on
        // a higher limit lets a run delete more, so it asks like switching on does
        case let .limit(n): n > (current?.max_deletions ?? 10)
        case let .rule(on): on
        case let .save(enabled): enabled
        case .delete, .unkeep, .clearKept: true
        case let .run(dry): !dry
        case .keep: false
        }
    }

    public func asks(_ change: Change) -> Bool { Self.asks(change, current: settings) }

    public var settings: CleanupRulesSettings? { rules.value?.settings }
    public var enabled: Bool { settings?.enabled ?? false }
    public var maxDeletions: Int { settings?.max_deletions ?? 10 }
    public var drafts: [RuleDraft] { (rules.value?.rules ?? []).map(RuleDraft.init) }
    public var canAddRule: Bool { drafts.count < RuleDraft.maxRules }

    /// The usual limits, plus the current one if the web app set another.
    public var limitChoices: [Int] { Array(Set(Self.limitChoices + [maxDeletions])).sorted() }

    public func load() async {
        await withDiscardingTaskGroup { group in
            group.addTask { await self.loadRules() }
            group.addTask { await self.loadLeaving() }
            group.addTask { await self.loadKept() }
            group.addTask { await self.loadLog() }
        }
    }

    private func loadRules() async { await fetch(\.rules) { try await api.cleanupRules() } }
    private func loadLeaving() async { await fetch(\.leaving) { try await api.leaving() } }
    private func loadKept() async { await fetch(\.kept) { try await api.kept() } }
    private func loadLog() async { await fetch(\.log) { try await api.cleanupLog() } }

    // MARK: Switches and rules

    public func setCleanup(on: Bool) async {
        guard let settings else { return }
        var next = settings
        next.enabled = on
        // switching off releases everything that was leaving, and says so in the log
        if await persist(settings: next, rules: drafts), !on {
            await loadLeaving()
            await loadLog()
        }
    }

    public func setLimit(_ limit: Int) async {
        guard let settings, (1...100).contains(limit) else { return }
        var next = settings
        next.max_deletions = limit
        await persist(settings: next, rules: drafts)
    }

    public func setRule(_ id: String, on: Bool) async {
        guard let settings else { return }
        await persist(settings: settings, rules: drafts.map { draft in
            var draft = draft
            if draft.id == id { draft.enabled = on }
            return draft
        })
    }

    /// Adds a new rule or replaces the saved one with the same id. Saving
    /// never switches a rule on or off; the draft keeps the state it had.
    @discardableResult
    public func save(_ draft: RuleDraft) async -> Bool {
        guard let settings, draft.canSave else { return false }
        var list = drafts
        if let index = list.firstIndex(where: { !draft.isNew && $0.id == draft.id }) {
            list[index] = draft
        } else {
            guard list.count < RuleDraft.maxRules else { return false }
            list.append(draft)
        }
        return await persist(settings: settings, rules: list)
    }

    @discardableResult
    public func delete(_ id: String) async -> Bool {
        guard let settings, !id.isEmpty else { return false }
        return await persist(settings: settings, rules: drafts.filter { $0.id != id })
    }

    /// PUT replaces the switch and the whole list, so every change sends all
    /// of it, and the answer (new rules' ids included) replaces what is shown.
    @discardableResult
    private func persist(settings: CleanupRulesSettings, rules list: [RuleDraft]) async -> Bool {
        saving = true
        defer { saving = false }
        do {
            rules = .loaded(try await api.saveCleanupRules(settings: settings, rules: list))
            return true
        } catch {
            self.error = Self.describe(error)
            return false
        }
    }

    // MARK: Preview

    /// What the draft would take right now. Stale answers are dropped, so a
    /// slow one never overwrites the preview of a later edit.
    public func updatePreview(_ draft: RuleDraft) async {
        previewGeneration += 1
        let mine = previewGeneration
        guard let probe = draft.probe else {
            preview = .needsCondition
            return
        }
        preview = .loading
        do {
            let answer = try await api.previewRule(probe)
            guard mine == previewGeneration else { return }
            preview = .loaded(answer)
        } catch {
            guard mine == previewGeneration else { return }
            preview = .failed(Self.describe(error))
        }
    }

    public func resetPreview() {
        previewGeneration += 1
        preview = .idle
    }

    // MARK: Keep list

    public func keep(_ kind: CleanupKind, id: Int, title: String, year: Int?) async {
        let key = "\(kind.rawValue):\(id)"
        keeping.insert(key)
        defer { keeping.remove(key) }
        do {
            try await api.keep(kind, id: id, title: title, year: year)
            await loadLeaving()
            await loadKept()
        } catch {
            self.error = Self.describe(error)
        }
    }

    public func unkeep(_ item: CleanupKept) async {
        keeping.insert(item.key)
        defer { keeping.remove(item.key) }
        do {
            try await api.unkeep(item.cleanupKind, id: item.id)
            await loadKept()
        } catch {
            self.error = Self.describe(error)
        }
    }

    public func clearKept() async {
        do {
            try await api.clearKept()
            await loadKept()
        } catch {
            self.error = Self.describe(error)
        }
    }

    // MARK: Runs

    /// A test run changes nothing and is not logged; a real one deletes what
    /// is due and still matches.
    public func run(dry: Bool) async {
        running = true
        defer { running = false }
        do {
            result = try await api.runCleanup(dryRun: dry)
            if !dry {
                await loadLog()
                await loadLeaving()
            }
        } catch {
            self.error = Self.describe(error)
        }
    }

    static func describe(_ error: any Error) -> String {
        (error as? CleanupRulesError)?.description ?? (error as? APIError)?.description ?? error.localizedDescription
    }

    private func fetch<V: Sendable & Equatable>(
        _ keyPath: ReferenceWritableKeyPath<CleanupRulesModel, Loadable<V>>, _ work: () async throws -> V
    ) async {
        do {
            self[keyPath: keyPath] = .loaded(try await work())
        } catch {
            // a refresh that fails keeps what is shown
            if self[keyPath: keyPath].value == nil { self[keyPath: keyPath] = .failed(Self.describe(error)) }
        }
    }
}
