import ArrdeckData
import SwiftUI

/// The PWA's dashboard, natively. Cards appear in the same order and hide on
/// the same conditions: a card that only ever said "all good" trains you to
/// stop reading it, so the alerting ones (health, requests, queue) exist only
/// while there is something to act on.
public struct DashboardView: View {
    let model: DashboardModel
    let baseURL: URL
    let api: any DownloadsAPI & LibraryAPI & WantedAPI & CalendarAPI & HistoryAPI & ExtrasAPI
    let onSessionLost: @MainActor () -> Void
    /// Pushed programmatically: a NavigationLink nested in the poster strip's
    /// horizontal ScrollView inside a List row never fires, a Button does.
    @State private var opened: MediaRef?

    public init(
        model: DashboardModel, baseURL: URL, api: any DownloadsAPI & LibraryAPI & WantedAPI & CalendarAPI & HistoryAPI & ExtrasAPI,
        onSessionLost: @escaping @MainActor () -> Void
    ) {
        self.model = model
        self.baseURL = baseURL
        self.api = api
        self.onSessionLost = onSessionLost
    }

    public var body: some View {
        List {
            if let error = model.connectionError {
                Section {
                    Label(error, systemImage: "wifi.slash")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("connection-error")
                }
            }
            NowPlayingSection(model: model)
            HealthSection(model: model)
            RequestsSection(model: model, baseURL: baseURL)
            RecentSection(model: model, baseURL: baseURL) { opened = $0 }
            TorrentSection(model: model)
            QueueSection(model: model)
            if model.hasArr {
                CalendarSection(model: model) {
                    CalendarScreen(api: api, onSessionLost: onSessionLost)
                }
                StorageSection(model: model)
            }
            if model.has("gluetun") { VpnSection(model: model) }
            if model.has("bazarr") { SubtitlesSection(model: model) }
            if model.hasArr {
                HistorySection(model: model) { HistoryScreen(api: api, onSessionLost: onSessionLost) }
            }
            if model.has("prowlarr") { IndexerSection(model: model) }
            TrendsSection(model: model) { StatsScreen(api: api, onSessionLost: onSessionLost) }
        }
        .dashboardListStyle()
        .refreshable { await model.refresh() }
        .task { await model.run() }
        // NavigationLink(value:) takes the optional ref and pushes the wrapped
        // value, so the destination is registered for MediaRef, not MediaRef?.
        .navigationDestination(for: MediaRef.self) { ref in destination(ref) }
        .navigationDestination(item: $opened) { ref in destination(ref) }
        .toolbar {
            if model.hasArr {
                NavigationLink {
                    WantedView(
                        api: api, apps: ArrApp.allCases.filter { model.has($0.rawValue) },
                        baseURL: baseURL, hasPlex: model.has("plex"), onSessionLost: onSessionLost
                    )
                } label: {
                    Label("Wanted", systemImage: "magnifyingglass.circle")
                }
                .accessibilityIdentifier("wanted-link")
            }
        }
        .alert("Action failed", isPresented: actionFailed) {
            Button("OK") { model.actionError = nil }
        } message: {
            Text(model.actionError ?? "")
        }
        .accessibilityIdentifier("dashboard")
    }

    var actionFailed: Binding<Bool> {
        Binding(
            get: { model.actionError != nil },
            set: { if !$0 { model.actionError = nil } }
        )
    }

    @ViewBuilder func destination(_ ref: MediaRef) -> some View {
        switch ref {
        case let .movie(id):
            MovieDetailView(id: id, api: api, baseURL: baseURL, hasPlex: model.has("plex"), onSessionLost: onSessionLost)
        case let .series(id):
            SeriesDetailView(id: id, api: api, baseURL: baseURL, hasPlex: model.has("plex"), onSessionLost: onSessionLost)
        case let .book(id):
            BookDetailView(id: id, api: api, baseURL: baseURL, onSessionLost: onSessionLost)
        }
    }
}

// MARK: - Alerting cards: only shown while there is something to see

struct NowPlayingSection: View {
    let model: DashboardModel

    var body: some View {
        if model.has("plex"), let sessions = model.sessions.value?.value, !sessions.isEmpty {
            Section("Now playing") {
                ForEach(Array(sessions.enumerated()), id: \.offset) { _, session in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.title ?? "").font(.subheadline.weight(.medium)).lineLimit(1)
                        if let subtitle = session.subtitle {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        HStack(spacing: 6) {
                            StateBadge(state: session.state == "paused" ? "paused" : "playing")
                            Text(details(session)).font(.caption).foregroundStyle(.secondary)
                        }
                        ProgressBar(value: session.progress ?? 0)
                    }
                }
            }
        }
    }

    func details(_ session: PlaySession) -> String {
        var parts = [session.user ?? ""]
        if let player = session.player, !player.isEmpty { parts.append(player) }
        if session.transcoding == true { parts.append("transcoding") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct HealthSection: View {
    let model: DashboardModel

    var body: some View {
        if model.hasArr, let warnings = model.health.value?.value, !warnings.isEmpty {
            Section("Needs attention") {
                ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            StateBadge(state: warning.app)
                            StateBadge(state: warning.level == "error" ? "error" : "warning")
                        }
                        Text(warning.message ?? "").font(.subheadline)
                    }
                }
            }
        }
    }
}

/// Pending Overseerr requests, with the approve/decline that would otherwise
/// mean opening Overseerr.
struct RequestsSection: View {
    let model: DashboardModel
    let baseURL: URL

    var body: some View {
        if model.has("overseerr"), let requests = model.requests.value?.value, !requests.isEmpty {
            Section("Pending requests") {
                ForEach(requests, id: \.id) { request in
                    HStack(spacing: 12) {
                        if request.poster != nil {
                            Poster(path: request.poster, baseURL: baseURL)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 4) {
                                Text(request.title ?? "#\(request.id)").font(.subheadline.weight(.medium)).lineLimit(1)
                                if let year = request.year {
                                    Text("(\(year))").font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            HStack(spacing: 6) {
                                StateBadge(state: request._type == "tv" ? "sonarr" : "radarr")
                                Text(requester(request)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        VStack(spacing: 6) {
                            actionButton("Approve", .approve, request).tint(.green)
                            actionButton("Decline", .decline, request).tint(.red)
                        }
                    }
                }
            }
        }
    }

    func requester(_ request: MediaRequest) -> String {
        var text = request.requested_by ?? ""
        if let seasons = request.seasons, !seasons.isEmpty {
            text += " · \(seasons.count) season(s)"
        }
        return text
    }

    func actionButton(_ title: String, _ action: RequestAction, _ request: MediaRequest) -> some View {
        Button(title) { Task { await model.act(on: request, action) } }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.isPending("request-\(request.id)"))
    }
}

// MARK: - Activity

struct RecentSection: View {
    let model: DashboardModel
    let baseURL: URL
    let open: (MediaRef) -> Void

    var body: some View {
        if let recent = model.recent.value, !recent.isEmpty {
            Section("Recently added") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(Array(recent.enumerated()), id: \.offset) { _, item in
                            Button {
                                if let ref = item.ref { open(ref) }
                            } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                if item.poster != nil {
                                    Poster(path: item.poster, baseURL: baseURL, width: 92, cornerRadius: 12)
                                } else {
                                    Text(item.title)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                        .frame(width: 92, height: 138)
                                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                                }
                                Text(item.title).font(.caption.weight(.semibold)).lineLimit(1)
                                Text(item.subtitle ?? " ").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(width: 92)
                            }
                            .buttonStyle(.plain)
                            .disabled(item.ref == nil)
                            .accessibilityIdentifier("recent-poster")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .listRowInsets(EdgeInsets())
            }
        }
    }
}

struct TorrentSection: View {
    let model: DashboardModel
    @State private var collapsed: Set<TorrentClient> = []

    var body: some View {
        let clients = model.torrentClients
        if !clients.isEmpty {
            Section("Torrent activity") {
                RefreshNote(error: model.cardErrors[.torrents])
                ForEach(clients, id: \.self) { client in
                    BlockRows(state: model.torrents.slice(client)) { summary in
                        Button {
                            if collapsed.contains(client) { collapsed.remove(client) } else { collapsed.insert(client) }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 12) {
                                    Text("\(collapsed.contains(client) ? "▸" : "▾") \(Services.label(client.rawValue))")
                                        .font(.subheadline.weight(.semibold))
                                    Text("↓ \(Format.speed(summary.totals.dl_speed))")
                                    Text("↑ \(Format.speed(summary.totals.ul_speed))")
                                }
                                .font(.subheadline)
                                Text("\(summary.count ?? 0) torrents, \(summary.active_count ?? 0) active")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("torrents-\(client.rawValue)")

                        if !collapsed.contains(client) {
                            ForEach(summary.active ?? [], id: \.id) { torrent in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(torrent.name).font(.subheadline.weight(.medium)).lineLimit(1)
                                    HStack(spacing: 8) {
                                        StateBadge(state: torrent.state)
                                        Text("↓\(Format.speed(torrent.dl_speed)) ↑\(Format.speed(torrent.ul_speed))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    ProgressBar(value: torrent.progress)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

struct QueueSection: View {
    let model: DashboardModel

    var body: some View {
        if model.hasArr, let blocks = model.queue.value {
            let items = ArrApp.allCases.flatMap { blocks[$0]?.value ?? [] }
            // A stale block also has ok=false, but it has data and an age —
            // calling that "offline" would print a missing error while listing
            // the items below it.
            let offline = ArrApp.allCases.compactMap { app in
                model.has(app.rawValue) ? blocks[app]?.offlineReason.map { (app, $0) } : nil
            }
            let stale = ArrApp.allCases.compactMap { app in
                model.has(app.rawValue) ? blocks[app]?.staleAge.map { (app, $0) } : nil
            }
            if !items.isEmpty || !offline.isEmpty || !stale.isEmpty {
                Section("Download queue") {
                RefreshNote(error: model.cardErrors[.queue])
                    ForEach(offline, id: \.0) { app, reason in
                        ErrorNote("\(Services.label(app.rawValue)) offline — \(reason)")
                    }
                    ForEach(stale, id: \.0) { _, age in
                        StaleNote(age: age)
                    }
                    ForEach(items, id: \.id) { item in
                        QueueRow(
                            item: item,
                            pending: model.isPending("queue-\(item.app.rawValue)-\(item.id)"),
                            forceImport: { Task { await model.forceImport(item) } },
                            retry: { Task { await model.blocklistRetry(item) } }
                        )
                    }
                }
            }
        }
    }
}

struct QueueRow: View {
    let item: QueueItem
    let pending: Bool
    let forceImport: () -> Void
    let retry: () -> Void
    var remove: (() -> Void)? = nil

    var troubled: Bool {
        !(item.errors ?? []).isEmpty || item.tracked_status == "warning" || item.tracked_status == "error"
    }

    var badge: String {
        if !(item.errors ?? []).isEmpty || item.tracked_status == "error" { return "error" }
        if item.tracked_status == "warning" { return "warning" }
        return item.status
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.subheadline.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    StateBadge(state: item.app.rawValue)
                    StateBadge(state: badge)
                    Text(item.time_left ?? "").font(.caption).foregroundStyle(.secondary)
                }
                ProgressBar(value: item.size > 0 ? (item.size - item.size_left) / item.size : 0)
                if let first = item.errors?.first {
                    Text(first).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            VStack(spacing: 6) {
                if let state = item.tracked_state, state.hasPrefix("import"), state != "imported" {
                    Button("Force import", action: forceImport)
                        .buttonStyle(.bordered).controlSize(.small)
                }
                if troubled {
                    Button("Blocklist & retry", action: retry)
                        .buttonStyle(.bordered).controlSize(.small).tint(.orange)
                }
                if let remove {
                    Button("Remove", role: .destructive, action: remove)
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            .disabled(pending)
        }
    }
}

struct CalendarSection<Destination: View>: View {
    let model: DashboardModel
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        Section {
            RefreshNote(error: model.cardErrors[.calendar])
            switch model.calendar {
            case .loading:
                LoadingRow()
            case let .failed(reason):
                ErrorNote(reason)
            case let .loaded(blocks):
                let merged = ArrApp.allCases.flatMap { blocks[$0]?.value ?? [] }
                    .sorted { ($0.date ?? "\u{FFFF}") < ($1.date ?? "\u{FFFF}") }
                let unreachable = ArrApp.allCases.contains { model.has($0.rawValue) && blocks[$0]?.offlineReason != nil }
                ForEach(ArrApp.allCases, id: \.self) { app in
                    if model.has(app.rawValue), let reason = blocks[app]?.offlineReason {
                        ErrorNote("\(Services.label(app.rawValue)) offline — \(reason)")
                    }
                }
                // Only claim nothing is scheduled when both arrs answered.
                if merged.isEmpty && !unreachable {
                    EmptyNote("Nothing scheduled")
                }
                ForEach(Array(merged.prefix(15).enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.subheadline.weight(.medium)).lineLimit(1)
                            HStack(spacing: 6) {
                                StateBadge(state: item.app.rawValue)
                                if let kind = item.release_type { StateBadge(state: kind.capitalized) }
                                Text(item.extra ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        if item.has_file == true {
                            StateBadge(state: "downloaded")
                        } else {
                            Text(Format.day(item.date)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text("Upcoming (14 days)")
                Spacer()
                NavigationLink { destination() } label: {
                    Text("See all →").font(.caption.weight(.semibold)).textCase(nil)
                }
                .accessibilityIdentifier("calendar-link")
            }
        }
    }
}

struct HistorySection<Destination: View>: View {
    let model: DashboardModel
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        Section {
            RefreshNote(error: model.cardErrors[.history])
            switch model.history {
            case .loading:
                LoadingRow()
            case let .failed(reason):
                ErrorNote(reason)
            case let .loaded(blocks):
                let merged = ArrApp.allCases.flatMap { blocks[$0]?.value ?? [] }.sorted { $0.date > $1.date }
                ForEach(ArrApp.allCases, id: \.self) { app in
                    if model.has(app.rawValue), let reason = blocks[app]?.offlineReason {
                        ErrorNote("\(Services.label(app.rawValue)) offline — \(reason)")
                    }
                }
                if merged.isEmpty {
                    EmptyNote("Nothing grabbed yet")
                }
                ForEach(Array(merged.prefix(12).enumerated()), id: \.offset) { _, item in
                    NavigationLink(value: item.ref) {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).font(.subheadline.weight(.medium)).lineLimit(1)
                                HStack(spacing: 4) {
                                    StateBadge(state: item.app.rawValue)
                                    ForEach(item.events ?? [], id: \._type) { event in
                                        StateBadge(state: event._type)
                                    }
                                }
                            }
                            Spacer(minLength: 0)
                            Text(Format.dayTime(item.date)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(item.ref == nil)
                }
            }
        } header: {
            HStack {
                Text("Recent history")
                Spacer()
                NavigationLink { destination() } label: {
                    Text("See all →").font(.caption.weight(.semibold)).textCase(nil)
                }
                .accessibilityIdentifier("history-link")
            }
        }
    }
}

// MARK: - Status cards

struct StorageSection: View {
    let model: DashboardModel

    var body: some View {
        Section("Storage") {
            RefreshNote(error: model.cardErrors[.diskSpace])
            BlockRows(state: model.diskSpace) { disks in
                ForEach(disks, id: \.path) { disk in
                    let free = disk.free_bytes ?? 0
                    let total = disk.total_bytes ?? 0
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(disk.path).font(.caption.monospaced()).lineLimit(1)
                            Spacer()
                            Text("\(Format.bytes(free)) free").font(.subheadline.weight(.semibold))
                        }
                        HStack(spacing: 6) {
                            StateBadge(state: disk.label ?? "")
                            if total > 0 { Text(Format.bytes(total)).font(.caption).foregroundStyle(.secondary) }
                        }
                        // Root folders report no total, so a bar is only honest
                        // when a matching mount supplied one.
                        if total > 0 {
                            ProgressBar(value: Double(total - free) / Double(total))
                        }
                    }
                }
            }
        }
    }
}

struct VpnSection: View {
    let model: DashboardModel

    var body: some View {
        Section("VPN") {
            RefreshNote(error: model.cardErrors[.vpn])
            BlockRows(state: model.vpn) { vpn in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        StateBadge(state: vpn.status == "running" ? "ok" : "error")
                        Text(vpn.public_ip?.isEmpty == false ? vpn.public_ip! : "—")
                            .font(.subheadline.weight(.medium))
                    }
                    Text([vpn.city, vpn.country].compactMap { $0 }.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text("Forwarded port \(vpn.forwarded_port.map(String.init) ?? "—")")
                            .foregroundStyle(.secondary)
                        // A forwarded port the client is not listening on is
                        // silently unconnectable — worth calling out.
                        if vpn.port_matches == false {
                            StateBadge(state: "warning")
                            Text("qBittorrent is on \(vpn.client_port.map(String.init) ?? "—")")
                                .foregroundStyle(.orange)
                        }
                    }
                    .font(.caption)
                }
            }
        }
    }
}

struct SubtitlesSection: View {
    let model: DashboardModel

    var body: some View {
        if let subs = model.subtitles.value?.value, (subs.movies ?? 0) + (subs.episodes ?? 0) > 0 {
            Section("Subtitles") {
                HStack {
                    Text("\(subs.movies ?? 0) movies, \(subs.episodes ?? 0) episodes missing subtitles")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    // Bazarr's badge counts throttled providers, so non-zero is
                    // the problem — a throttled provider silently returns nothing.
                    if (subs.throttled_providers ?? 0) > 0 {
                        Text("\(subs.throttled_providers ?? 0) provider throttled")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                ForEach((subs.items ?? []).prefix(8), id: \.id) { item in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title ?? "").font(.subheadline.weight(.medium)).lineLimit(1)
                            HStack(spacing: 6) {
                                StateBadge(state: item.kind == "episode" ? "sonarr" : "radarr")
                                Text([item.subtitle, (item.missing ?? []).isEmpty ? nil : (item.missing ?? []).joined(separator: ", ")]
                                    .compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        Button("Search") { Task { await model.searchSubtitles(item) } }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(model.isPending("subtitles-\(item.kind)-\(item.id)"))
                    }
                }
            }
        }
    }
}

struct IndexerSection: View {
    let model: DashboardModel

    var body: some View {
        Section("Indexers") {
            RefreshNote(error: model.cardErrors[.indexers])
            BlockRows(state: model.indexers) { stats in
                HStack(spacing: 8) {
                    Text("\(stats.enabled)/\(stats.total) enabled").font(.subheadline)
                    ForEach(Array(stats.health.enumerated()), id: \.offset) { _, item in
                        StateBadge(state: "warning")
                            .help(item.message ?? "")
                    }
                }
                ForEach(Array(stats.stats.enumerated()), id: \.offset) { _, indexer in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(indexer.name ?? "").font(.subheadline.weight(.medium))
                            Text("\(indexer.queries ?? 0) queries · \(indexer.grabs ?? 0) grabs")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(indexer.avg_response_ms ?? 0) ms").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct TrendsSection<Destination: View>: View {
    let model: DashboardModel
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        if let samples = model.trends.value, samples.count >= 2, let last = samples.last {
            // ?? 0 throughout: these fields are optional, and a snapshot taken
            // while an arr was down must not blank the tile.
            let tiles: [(String, String, [Double])] = [
                ("Library size", Format.bytes(last.library_bytes), samples.map { Double($0.library_bytes ?? 0) }),
                ("Movies", String(last.movies ?? 0), samples.map { Double($0.movies ?? 0) }),
                ("Series", String(last.series ?? 0), samples.map { Double($0.series ?? 0) }),
                ("Grabs", String(last.indexer_grabs ?? 0), samples.map { Double($0.indexer_grabs ?? 0) }),
            ]
            Section {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(tiles, id: \.0) { label, value, values in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label).font(.caption).foregroundStyle(.secondary)
                            Text(value).font(.headline)
                            Sparkline(values: values)
                        }
                        .padding(12)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(.vertical, 4)
            } header: {
                HStack {
                    Text("Trends (30 days)")
                    Spacer()
                    NavigationLink { destination() } label: {
                        Text("See all →").font(.caption.weight(.semibold)).textCase(nil)
                    }
                    .accessibilityIdentifier("stats-link")
                }
            }
        }
    }
}
