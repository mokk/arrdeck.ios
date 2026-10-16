import ArrdeckData
import ArrdeckGlance
import Foundation
import SwiftUI
import WidgetKit
#if os(iOS) && canImport(ActivityKit)
import ActivityKit
#endif

/// Invisible, beside the tabs: it alone watches the poll times, so a poll
/// every five seconds re-renders nothing on screen.
struct GlanceFeed: View {
    let model: DashboardModel
    let server: String
    /// Where the posters are fetched from: the address answering now.
    /// The Activity widget's feed: one record per episode, where the
    /// dashboard's history has one per torrent (a season pack is one row).
    let api: any ActivityAPI
    @State private var recent: [ActivityEvent]?
    /// How far back the Activity widget looks, and how often.
    static let lookback: TimeInterval = 14 * 86400
    static let every: Duration = .seconds(300)
    @AppStorage(DisplayKeys.liveActivity) private var liveActivity = true
    @Environment(\.scenePhase) private var scenePhase

    var answered: [Date?] {
        [model.answeredAt[.torrents], model.answeredAt[.calendar], model.answeredAt[.diskSpace]]
    }

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .onChange(of: answered, initial: true) { publish() }
            .onChange(of: liveActivity) { publish() }
            // Activity's titles and posters arrive after its history: the
            // libraries load on their own, the posters one by one
            .onChange(of: LibraryTitles.shared.titles) { publish() }
            .onChange(of: GlancePosters.shared.stored) { publish() }
            .onChange(of: recent) { publish() }
            .task(id: server) { await pollRecent() }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background: GlancePublisher.shared.flush()
                case .active: GlancePublisher.shared.returned()
                default: break
                }
            }
    }

    func publish() {
        // the polls answer only while in front; this is belt and braces
        guard scenePhase != .background else { return }
        GlancePublisher.shared.publish(model, recent: recent, server: server, liveActivity: liveActivity)
    }

    /// The last two weeks of the arrs' events, every few minutes while open.
    /// A failure keeps the last answer; the Activity tab's own poll is the
    /// one that reports it.
    func pollRecent() async {
        while !Task.isCancelled {
            if let since = try? await api.activitySince(.now.addingTimeInterval(-Self.lookback)) {
                recent = since.items
            }
            try? await Task.sleep(for: Self.every)
        }
    }
}

/// Keeps the widgets and the Live Activity in step with the dashboard while
/// the app is open. The dashboard model already polls everything they show;
/// this only copies it out after each poll.
@MainActor
final class GlancePublisher {
    static let shared = GlancePublisher()

    private let store = GlanceStore()
    private var written: GlanceSnapshot?
    /// Widget reloads are rationed by iOS; a foreground app's are free, but
    /// a timeline rebuilt every five seconds still churns for nothing.
    static let reloadEvery: TimeInterval = 60
    private var lastReload: Date = .distantPast
    private var trailingReload: Task<Void, Never>?
    #if os(iOS) && canImport(ActivityKit)
    let liveActivity = DownloadsLiveActivity()
    #endif

    /// After any of the dashboard's torrent, calendar or disk polls, and when
    /// Activity's feed, titles or posters change.
    func publish(_ model: DashboardModel, recent: [ActivityEvent]?, server: String,
                 liveActivity enabled: Bool, now: Date = .now) {
        // until /services answers, "no torrent client" only means "not known
        // yet", and would end an activity adopted from the last run
        guard model.servicesKnown else { return }
        let byteBase = UserDefaults.standard.pref(DisplayKeys.sizes, default: SizeStyle.binary) == .decimal ? 1000 : 1024
        let fresh = GlanceSnapshot.make(
            server: server,
            torrents: model.torrentClients.isEmpty ? nil : model.torrents.value,
            calendar: model.hasArr ? model.calendar.value : nil,
            disks: model.hasArr ? model.diskSpace.value : nil,
            activity: model.hasArr ? recent : nil,
            titles: LibraryTitles.shared.titles,
            posters: GlancePosters.shared.stored,
            byteBase: byteBase, now: now
        )
        #if os(iOS) && canImport(ActivityKit)
        // ActivityKit needs no shared container, so this runs either way
        if fresh.downloads != nil || model.torrentClients.isEmpty {
            liveActivity.show(DownloadsActivityState(fresh.downloads, byteBase: byteBase),
                              server: server, enabled: enabled)
        }
        #endif
        // without the App Group there is nowhere to write; the app carries on
        guard store.isAvailable, !fresh.isEmpty else { return }
        let previous = written ?? store.read()
        let merged = fresh.merging(previous)
        if let entries = merged.activity?.entries {
            GlancePosters.shared.update(for: entries, titles: LibraryTitles.shared.titles)
        }
        guard merged != previous else { return }
        store.write(merged)
        written = merged
        // a download starting or finishing is worth showing at once
        // and so is something arriving, or its poster landing
        let changed = previous?.downloads?.count != merged.downloads?.count || previous?.server != merged.server
            || previous?.activity?.entries != merged.activity?.entries
        reloadWidgets(now: now, force: changed)
    }

    /// Leaving the app: the widgets get the latest at once, since nothing
    /// will update them until it is opened again.
    func flush() {
        guard trailingReload != nil else { return }
        reloadWidgets(now: .now, force: true)
    }

    /// Back in front.
    func returned() {
        #if os(iOS) && canImport(ActivityKit)
        liveActivity.returned()
        #endif
    }

    private func reloadWidgets(now: Date, force: Bool) {
        let wait = lastReload.addingTimeInterval(Self.reloadEvery).timeIntervalSince(now)
        if force || wait <= 0 {
            trailingReload?.cancel()
            trailingReload = nil
            lastReload = now
            WidgetCenter.shared.reloadAllTimelines()
        } else if trailingReload == nil {
            // throttled, not dropped: the last write of the minute still lands
            trailingReload = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, let self else { return }
                trailingReload = nil
                lastReload = .now
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }
}

#if os(iOS) && canImport(ActivityKit)
/// One Live Activity while the app is open and something is downloading.
///
/// It is updated only from the app's own polls: without push (which a free
/// signature cannot have) nothing reaches it once the app is suspended. Each
/// update therefore carries a stale date a few minutes on, which the system
/// passes when the app has been away too long, and the views then say the
/// numbers are old. It ends when nothing is downloading, when it is switched
/// off, and on the app's return if it went stale meanwhile.
@MainActor
final class DownloadsLiveActivity {
    typealias Live = Activity<DownloadsActivityAttributes>
    /// Kept by id and looked up when needed: an Activity is not Sendable, so
    /// it cannot be held here and handed to the async update.
    private var activityID: String?
    private var sent: DownloadsActivityState?
    private var sentAt: Date = .distantPast
    /// Re-sent at least this often while open, so the stale date keeps moving.
    static let keepAlive: TimeInterval = 60

    init() {
        // one from an earlier run is adopted, not duplicated
        activityID = Live.activities.first?.id
    }

    private var current: Live? {
        Live.activities.first { $0.id == activityID }
    }

    func show(_ state: DownloadsActivityState?, server: String, enabled: Bool, now: Date = .now) {
        guard enabled, let state, ActivityAuthorizationInfo().areActivitiesEnabled else {
            end()
            return
        }
        let content = ActivityContent(state: state, staleDate: now.addingTimeInterval(DownloadsActivityState.staleAfter))
        if let current, current.activityState == .active || current.activityState == .stale,
           current.attributes.server == server {
            if let sent, sent.looksLike(state), now.timeIntervalSince(sentAt) < Self.keepAlive { return }
            sent = state
            sentAt = now
            let id = current.id
            Task { await Self.update(id, content) }
            return
        }
        end()
        // starting needs the app in front; a poll finishing just after it
        // left simply starts nothing
        activityID = (try? Live.request(attributes: DownloadsActivityAttributes(server: server), content: content))?.id
        sent = state
        sentAt = now
    }

    /// Back in front: one left stale while away is ended rather than left
    /// showing old numbers; the next poll starts a fresh one if still needed.
    func returned() {
        guard let current, current.activityState == .stale else { return }
        end()
    }

    func end() {
        activityID = nil
        sent = nil
        // the ids now, not when the task runs: a request made right after
        // this call must not be swept up and ended with the old ones
        let ids = Live.activities.map(\.id)
        guard !ids.isEmpty else { return }
        Task { await Self.end(ids) }
    }

    // Off the main actor and looked up inside: an Activity is not Sendable,
    // so one fetched on the main actor cannot be handed to its own async calls.
    nonisolated private static func update(_ id: String, _ content: ActivityContent<DownloadsActivityState>) async {
        for activity in Live.activities where activity.id == id { await activity.update(content) }
    }

    nonisolated private static func end(_ ids: [String]) async {
        for activity in Live.activities where ids.contains(activity.id) {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
#endif
