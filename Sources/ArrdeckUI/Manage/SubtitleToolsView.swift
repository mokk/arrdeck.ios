import ArrdeckData
import SwiftUI

/// Settings → Subtitles: everything Bazarr is still missing, and language
/// profiles handed out in bulk — a title without one never gets subtitles.
struct SubtitleToolsView: View {
    enum Tab: Hashable { case missing, profiles }

    let api: any SubtitleToolsAPI
    @State private var tab: Tab = .missing

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $tab) {
                Text("Missing").tag(Tab.missing)
                Text("Language profiles").tag(Tab.profiles)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Color.grouped)
            switch tab {
            case .missing: MissingSubtitlesList(api: api)
            case .profiles: LanguageProfilesEditor(api: api)
            }
        }
        .navigationTitle("Subtitles")
    }
}

private struct MissingSubtitlesList: View {
    static let page = 50

    let api: any SubtitleToolsAPI
    @State private var kind: SubtitleKind = .episode
    @State private var items: Loadable<[SubtitleItem]> = .loading
    @State private var total = 0
    @State private var busy: Set<String> = []
    @State private var notice: String?

    var body: some View {
        List {
            Section {
                Picker("Kind", selection: $kind) {
                    Text("Episodes").tag(SubtitleKind.episode)
                    Text("Movies").tag(SubtitleKind.movie)
                }
                .pickerStyle(.segmented)
            }
            switch items {
            case .loading: LoadingRow()
            case let .failed(reason): ErrorNote(reason)
            case let .loaded(rows):
                if rows.isEmpty { EmptyNote("Nothing is missing subtitles.") }
                if total > 0 {
                    Section {
                        HStack {
                            Text("\(total) missing subtitles").foregroundStyle(.secondary)
                            Spacer()
                            Button("Search all") { Task { await searchAll() } }
                                .buttonStyle(.bordered).controlSize(.small)
                                .disabled(busy.contains("all"))
                        }
                        if let notice { Text(notice).font(.caption).foregroundStyle(Color.success) }
                    }
                }
                Section {
                    ForEach(rows, id: \.id) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title ?? "").font(.subheadline.weight(.medium)).lineLimit(1)
                                Text(verbatim: [item.subtitle, (item.missing ?? []).joined(separator: ", ")]
                                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button("Search") { Task { await search(item) } }
                                .buttonStyle(.bordered).controlSize(.small)
                                .disabled(busy.contains("\(item.kind)-\(item.id)"))
                        }
                    }
                    if rows.count < total {
                        Button("Show more") { Task { await more(rows) } }
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .dashboardListStyle()
        .task(id: kind) { await load() }
        .refreshable { await load() }
    }

    func load() async {
        notice = nil
        do {
            let page = try await api.subtitlesWanted(kind: kind, start: 0, length: Self.page)
            total = page.total ?? 0
            items = .loaded(page.items ?? [])
        } catch {
            items = .failed(error.localizedDescription)
        }
    }

    func more(_ rows: [SubtitleItem]) async {
        guard let page = try? await api.subtitlesWanted(kind: kind, start: rows.count, length: Self.page) else { return }
        total = page.total ?? total
        items = .loaded(rows + (page.items ?? []))
    }

    func search(_ item: SubtitleItem) async {
        let key = "\(item.kind)-\(item.id)"
        busy.insert(key)
        try? await api.searchSubtitles(kind: kind, id: item.id, seriesID: item.series_id)
        busy.remove(key)
    }

    func searchAll() async {
        busy.insert("all")
        do {
            try await api.searchAllSubtitles(kind: kind)
            notice = String(localized: "Bazarr is searching for all of them")
        } catch {
            notice = error.localizedDescription
        }
        busy.remove("all")
    }
}

private struct LanguageProfilesEditor: View {
    let api: any SubtitleToolsAPI
    @State private var titles: Loadable<[SubtitleTitle]> = .loading
    @State private var profiles: [LanguageProfile] = []
    @State private var picker = ProfilePicks()
    /// nil is "No profile"
    @State private var target: Int?
    @State private var targetChosen = false
    @State private var saving = false
    @Environment(\.confirmCenter) private var confirmCenter

    var body: some View {
        List {
            Section {
                Picker("Kind", selection: Binding(get: { picker.movies }, set: { picker.show(movies: $0) })) {
                    Text("Shows").tag(false)
                    Text("Movies").tag(true)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Bazarr only fetches subtitles for titles with a language profile. Pick titles and give them one.")
            }
            switch titles {
            case .loading: LoadingRow()
            case let .failed(reason): ErrorNote(reason)
            case let .loaded(all):
                Section {
                    Toggle("Only titles without a profile (\(picker.unsetCount(all)))", isOn: $picker.onlyUnset)
                    Button(picker.allPicked(all) ? "Select none" : "Select all shown") { picker.toggleAll(all) }
                        .disabled(picker.shown(all).isEmpty)
                    Picker("Profile", selection: $target) {
                        ForEach(profiles, id: \.id) { profile in
                            Text(verbatim: "\(profile.name) (\((profile.languages ?? []).joined(separator: ", ")))")
                                .tag(Optional(profile.id))
                        }
                        Text("No profile").tag(Int?.none)
                    }
                    Button("Apply to \(picker.picked.count)") { apply() }
                        .disabled(picker.picked.isEmpty || saving)
                }
                let shown = picker.shown(all)
                if shown.isEmpty { EmptyNote("Every title has a language profile.") }
                Section {
                    ForEach(shown, id: \.id) { row in
                        Button { picker.toggle(row.id) } label: {
                            HStack {
                                Image(systemName: picker.picked.contains(row.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(picker.picked.contains(row.id) ? Color.accent : Color.secondary)
                                Text(row.title ?? "").lineLimit(1)
                                if let year = row.year { Text(verbatim: year).foregroundStyle(.secondary) }
                                Spacer()
                                Text(profileName(row.profile_id)).font(.caption).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(picker.picked.contains(row.id) ? .isSelected : [])
                    }
                }
            }
        }
        .dashboardListStyle()
        .task { await load() }
        .refreshable { await load() }
    }

    func profileName(_ id: Int?) -> String {
        guard let id else { return String(localized: "No profile") }
        return profiles.first { $0.id == id }?.name ?? "\(id)"
    }

    func load() async {
        do {
            async let rows = api.subtitleTitles()
            async let known = api.languageProfiles()
            profiles = try await known
            if !targetChosen { target = profiles.first?.id; targetChosen = true }
            titles = .loaded(try await rows)
        } catch {
            titles = .failed(error.localizedDescription)
        }
    }

    func apply() {
        let ids = Array(picker.picked)
        let action = String(localized: "Set profile to \(target.map { profileName($0) } ?? String(localized: "No profile"))")
        let subject = String(localized: "\(ids.count) titles")
        ask(confirmCenter, action, subject: subject) {
            saving = true
            do {
                try await api.assignProfile(movies: picker.movies, ids: ids, profileID: target)
                picker.picked = []
            } catch {
                titles = .failed(error.localizedDescription)
            }
            saving = false
            await load()
        }
    }
}
