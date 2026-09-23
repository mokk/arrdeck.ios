import ArrdeckData
import SwiftUI

/// The arrs' own System pages in one place: reachability, schedulers,
/// quality profiles, backups and logs.
struct SystemView: View {
    @State private var model: SystemModel

    init(configured: Set<String>, api: any ManageAPI, onSessionLost: @escaping @MainActor () -> Void) {
        _model = State(initialValue: SystemModel(configured: configured, api: api, onSessionLost: onSessionLost))
    }

    var body: some View {
        List {
            statusSection
            tasksSection
            ForEach(model.apps, id: \.self) { app in
                if let profiles = model.profiles[app] {
                    ProfilesSection(app: app, profiles: profiles)
                }
            }
            backupsSection
            logsSection
        }
        .dashboardListStyle()
        .navigationTitle("System")
        .task { await model.load() }
        .refreshable { await model.load() }
    }

    var statusSection: some View {
        Section("Services") {
            switch model.status {
            case .loading: LoadingRow()
            case let .failed(reason): ErrorNote(reason)
            case let .loaded(list):
                ForEach(list, id: \.service) { status in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(!status.ok ? Color.danger : (status.isFlaky ? Color.warning : Color.success))
                            .frame(width: 8, height: 8)
                        Text(Services.label(status.service.rawValue)).font(.subheadline.weight(.medium))
                        Spacer()
                        // An available update is worth knowing but is not a fault:
                        // flaky wins the dot, since a service that keeps dropping
                        // matters more than a version.
                        if !status.ok {
                            Text(status.error ?? "offline").font(.caption).foregroundStyle(Color.danger).lineLimit(1)
                        } else if status.isFlaky {
                            Text("flaky · \(status.retries ?? 0) retries").font(.caption).foregroundStyle(Color.warning)
                        } else {
                            Text(status.version ?? "").font(.caption).foregroundStyle(.secondary)
                            if let update = status.update_available {
                                Text("↑ \(update)").font(.caption).foregroundStyle(Color.warning)
                            }
                        }
                    }
                }
            }
        }
    }

    /// "Why hasn't anything been grabbed?" is usually answered by "RSS sync
    /// last ran six hours ago", which lived only in each arr's System → Tasks.
    var tasksSection: some View {
        Section {
            BlockRows(state: model.tasks) { tasks in
                HStack {
                    if model.overdueCount > 0 {
                        Text(model.overdueCount == 1 ? "1 task overdue" : "\(model.overdueCount) tasks overdue")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Color.warning)
                    } else {
                        Text("\(tasks.count) tasks, all on schedule").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Scope", selection: $model.showAllTasks) {
                        Text("Key").tag(false)
                        Text("All").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                }
                if model.shownTasks.isEmpty { EmptyNote("No tasks") }
                ForEach(model.shownTasks, id: \.name) { task in
                    HStack(spacing: 10) {
                        StateBadge(state: task.app)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(task.label).font(.subheadline.weight(.medium)).lineLimit(1)
                            Text(lastRan(task)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if task.overdue == true {
                            Text("\(Format.eta(Int(task.overdue_by_seconds ?? 0))) overdue")
                                .font(.caption.weight(.semibold)).foregroundStyle(Color.warning)
                        } else {
                            Text(relative(task.next_execution)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Scheduled tasks")
        }
    }

    func lastRan(_ task: ScheduledTask) -> String {
        var text = "Last ran \(relative(task.last_execution))"
        if let seconds = task.last_duration_seconds, seconds >= 1 { text += " · \(Format.eta(Int(seconds.rounded())))" }
        return text
    }

    func relative(_ iso: String?) -> String {
        guard let iso, let date = Format.parseDate(iso) else { return "—" }
        return date.formatted(.relative(presentation: .named))
    }

    /// The arrs keep their own backups on their own schedule — distinct from
    /// arrdeck's, which only covers arrdeck's settings.
    var backupsSection: some View {
        Section("Service backups") {
            BlockRows(state: model.backups) { backups in
                if backups.isEmpty { EmptyNote("No backups yet") }
                ForEach(Array(backups.enumerated()), id: \.offset) { _, backup in
                    HStack(spacing: 10) {
                        StateBadge(state: backup.app)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(backup.time.map { Format.dayTime($0) } ?? backup.name).font(.subheadline.weight(.medium))
                            Text([backup.kind, Format.bytes(backup.size_bytes)].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let url = backup.url.flatMap(URL.init(string:)) {
                            Link(destination: url) { Image(systemName: "arrow.down.circle") }
                        }
                    }
                }
            }
        }
    }

    /// Debugging a failed grab used to mean opening Radarr, then Sonarr, then
    /// Prowlarr in three tabs.
    var logsSection: some View {
        Section {
            if model.logApps.count > 1 {
                Picker("Service", selection: $model.logApp) {
                    ForEach(model.logApps, id: \.self) { Text(Services.label($0)).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Picker("Level", selection: $model.logLevel) {
                Text("All").tag(String?.none)
                ForEach(["error", "warn", "info"], id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .pickerStyle(.segmented)
            switch model.logs {
            case .loading: LoadingRow()
            case let .failed(reason): ErrorNote(reason)
            case let .loaded(entries):
                if entries.isEmpty { EmptyNote("Nothing logged") }
                ForEach(Array(entries.prefix(100).enumerated()), id: \.offset) { _, entry in
                    LogRow(entry: entry)
                }
            }
        } header: {
            Text("Logs")
        }
    }
}

struct LogRow: View {
    let entry: LogEntry

    var levelColor: Color {
        switch entry.level {
        case "error", "fatal": Color.danger
        case "warn": Color.warning
        default: .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text((entry.level ?? "").uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(levelColor)
                if let time = entry.time, let date = Format.parseDate(time) {
                    Text(date.formatted(.dateTime.hour().minute().second())).font(.caption2).foregroundStyle(.secondary)
                }
                Text(entry.logger ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(entry.message ?? "").font(.caption.monospaced())
            if let exception = entry.exception?.split(separator: "\n").first {
                Text(String(exception)).font(.caption2.monospaced()).foregroundStyle(Color.danger).lineLimit(2)
            }
        }
    }
}

/// Read-only: deciding what quality you want still means opening the arr,
/// but checking what you already asked for no longer does.
struct ProfilesSection: View {
    let app: ArrApp
    let profiles: QualityProfiles
    @State private var expanded: Set<Int> = []

    var body: some View {
        Section("\(Services.label(app.rawValue)) quality profiles") {
            let list = profiles.profiles ?? []
            if list.isEmpty { EmptyNote("No profiles") }
            ForEach(list, id: \.id) { profile in
                let items = profile.items ?? []
                let shown = expanded.contains(profile.id) ? items : items.filter { $0.allowed == true }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(profile.name).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(profile.upgrade_allowed == true ? "upgrades to \(profile.cutoff ?? "?")" : "no upgrades")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(shown.map { ($0.name) + ($0.is_group == true ? " *" : "") + ($0.is_cutoff == true ? " ◆" : "") }.joined(separator: "  "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    let rejected = items.count - items.filter { $0.allowed == true }.count
                    if rejected > 0 {
                        Button(expanded.contains(profile.id) ? "Show accepted only" : "Show \(rejected) rejected") {
                            if expanded.contains(profile.id) { expanded.remove(profile.id) } else { expanded.insert(profile.id) }
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderless)
                    }
                }
            }
            let formats = profiles.custom_formats ?? []
            Text(formats.isEmpty ? "No custom formats defined" : "Custom formats: \(formats.joined(separator: ", "))")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
