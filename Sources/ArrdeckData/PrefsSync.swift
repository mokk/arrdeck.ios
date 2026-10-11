import Foundation

/// Keeps the display preferences in step with the server, so they follow you
/// to your other devices. UserDefaults stays what the views read; this only
/// copies between it and GET/PUT /prefs. The PWA does the same (lib/prefsSync.ts)
/// with the same rules, so a change on either shows up on the other.
///
/// Every run is the same three steps: read the server's copy, decide with
/// `PrefsSyncPolicy`, then adopt it or push ours. A change schedules a run a
/// second later, so a burst of taps is one request, and only one run is ever
/// in flight. A failed request changes nothing locally; the unsent change
/// stays marked and goes out with the next run (the next change, or coming
/// back to the app).
@MainActor
public final class PrefsSyncModel {
    /// The two times that say who is ahead, per server: this device's
    /// choices live in one UserDefaults, but each server has its own clock
    /// and its own copy.
    struct State: Equatable {
        /// The server's updated_at at the last sync this device completed; 0 = never.
        var syncedAt = 0
        /// When the oldest unsent local change was made; 0 = nothing waiting.
        var changedAt = 0
    }

    private let api: any PrefsAPI
    private let defaults: UserDefaults
    private let stateKey: String
    private let now: @MainActor () -> Int
    private let debounce: Duration
    private let refreshAfter: Int
    /// Told after server values were written to storage, for what keeps its
    /// own copy in memory (the theme).
    private let onApplied: @MainActor () -> Void

    /// What storage held when last looked at, so a notification for some
    /// unrelated key, or one this model caused itself, is not taken for a change.
    private var seen: [String: PrefValue]
    /// While server values are being written to storage, the change
    /// notification they cause must not be taken for something the user did.
    private var applying = false
    private var running = false
    private var again = false
    private var pending: Task<Void, Never>?
    private var observer: (any NSObjectProtocol)?
    private var lastRun = 0

    public init(
        api: any PrefsAPI,
        profileID: UUID,
        defaults: UserDefaults = .standard,
        debounce: Duration = .seconds(1),
        refreshAfter: Duration = .seconds(60),
        now: @escaping @MainActor () -> Int = { Int(Date().timeIntervalSince1970 * 1000) },
        onApplied: @escaping @MainActor () -> Void = {}
    ) {
        self.api = api
        self.defaults = defaults
        stateKey = "prefsSync.\(profileID.uuidString)"
        self.now = now
        self.debounce = debounce
        self.refreshAfter = Int(refreshAfter.components.seconds * 1000)
        self.onApplied = onApplied
        seen = DisplaySync.collect(defaults)
    }

    // MARK: lifecycle

    /// Syncs now and again after each change, until the calling task is
    /// cancelled — which is when the session stops being usable or the server
    /// is closed.
    public func run() async {
        start()
        defer { stop() }
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
    }

    func start() {
        seen = DisplaySync.collect(defaults)
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteLocalChange() }
        }
        refresh()
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        pending?.cancel()
        pending = nil
    }

    /// Coming back to the app is when another device's change is most likely
    /// waiting; not so often that flicking in and out costs a request each time.
    public func refreshIfStale() {
        guard now() - lastRun >= refreshAfter else { return }
        refresh()
    }

    func refresh() {
        lastRun = now()
        schedule(after: .zero)
    }

    private func schedule(after delay: Duration) {
        pending?.cancel()
        pending = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.sync()
        }
    }

    // MARK: local changes

    /// Marks a choice made here as waiting to be sent. Called for every
    /// UserDefaults notification; only an actual difference counts.
    public func noteLocalChange() {
        guard !applying else { return }
        let current = DisplaySync.collect(defaults)
        guard current != seen else { return }
        seen = current
        var state = loadState()
        // Strictly increasing, so two changes in one millisecond are still
        // ordered, and never earlier than the copy it follows: a clock running
        // behind the server's would otherwise see the user's change lose to a
        // version it was made after.
        state.changedAt = max(now(), state.changedAt + 1, state.syncedAt + 1)
        saveState(state)
        schedule(after: debounce)
    }

    // MARK: sync

    /// One run, or a note to go round again if one is already in flight.
    public func sync() async {
        if running {
            again = true
            return
        }
        running = true
        defer { running = false }
        repeat {
            again = false
            do {
                try await cycle()
            } catch {
                // offline, signed out or the server is down: local choices are untouched
            }
        } while again && !Task.isCancelled
    }

    private func cycle() async throws {
        let server = try await api.prefs()
        let state = loadState()
        let action = PrefsSyncPolicy.decide(
            serverAt: server.updatedAt, syncedAt: state.syncedAt, changedAt: state.changedAt,
            hasLocalValues: DisplaySync.hasLocalValues(defaults)
        )
        switch action {
        case .apply:
            adopt(server)
        case .none:
            break
        case .push:
            // Keys another client wrote that this one does not know go back
            // with every push, otherwise an older app would erase a newer one's
            // preferences.
            let foreign = server.values.filter { !DisplaySync.keys.contains($0.key) }
            let sent = state.changedAt > 0 ? state.changedAt : now()
            let stored = try await api.putPrefs(values: foreign.merging(DisplaySync.collect(defaults)) { _, ours in ours }, updatedAt: sent)
            // changed again while the request was out: decide afresh, with both in view
            if loadState().changedAt != state.changedAt {
                again = true
                return
            }
            // a later updated_at than the one sent means another device's write won
            if stored.updatedAt > sent {
                adopt(stored)
            } else {
                saveState(State(syncedAt: stored.updatedAt, changedAt: 0))
            }
        }
    }

    private func adopt(_ server: StoredPrefs) {
        applying = true
        DisplaySync.apply(server.values, to: defaults)
        // what was just written is the new baseline, not a change of the user's
        seen = DisplaySync.collect(defaults)
        applying = false
        saveState(State(syncedAt: server.updatedAt, changedAt: 0))
        onApplied()
    }

    // MARK: state

    /// The server's updated_at at the last completed sync; 0 = never.
    public var syncedAt: Int { loadState().syncedAt }
    /// When the oldest unsent local change was made; 0 = nothing waiting.
    public var changedAt: Int { loadState().changedAt }

    func loadState() -> State {
        let stored = defaults.dictionary(forKey: stateKey) as? [String: Int] ?? [:]
        return State(syncedAt: stored["syncedAt"] ?? 0, changedAt: stored["changedAt"] ?? 0)
    }

    private func saveState(_ state: State) {
        defaults.set(["syncedAt": state.syncedAt, "changedAt": state.changedAt], forKey: stateKey)
    }
}
