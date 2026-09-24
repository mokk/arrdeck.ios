import ArrdeckData
import SwiftUI

/// Settings → Exclusions: what the arrs' lists and suggestions will not add back.
struct ExclusionsView: View {
    let api: any ToolsAPI
    @State private var rows: Loadable<[Exclusion]> = .loading
    @Environment(\.confirmCenter) private var confirmCenter

    var body: some View {
        List {
            switch rows {
            case .loading: LoadingRow()
            case let .failed(reason): ErrorNote(reason)
            case let .loaded(all):
                if all.isEmpty { EmptyNote("Nothing is excluded.") }
                ForEach(["radarr", "sonarr", "readarr"], id: \.self) { app in
                    let mine = all.filter { $0.app.rawValue == app }
                    if !mine.isEmpty {
                        Section(Services.label(app)) {
                            ForEach(mine, id: \.id) { exclusion in
                                HStack {
                                    Text(exclusion.title ?? "").lineLimit(1)
                                    if let year = exclusion.year { Text(verbatim: "\(year)").foregroundStyle(.secondary) }
                                    Spacer()
                                    Button("Allow again") {
                                        ask(confirmCenter, String(localized: "Allow again"), subject: exclusion.title) { await remove(exclusion) }
                                    }
                                    .buttonStyle(.bordered).controlSize(.small)
                                }
                            }
                        }
                    }
                }
            }
            Section {
            } footer: {
                Text("Titles the arrs' lists and suggestions will not add back — from Cleanup, Not interested, or the arrs themselves.")
            }
        }
        .dashboardListStyle()
        .navigationTitle("Exclusions")
        .task { await load() }
        .refreshable { await load() }
    }

    func load() async {
        do { rows = .loaded(try await api.exclusions()) } catch { rows = .failed(error.localizedDescription) }
    }

    func remove(_ exclusion: Exclusion) async {
        try? await api.removeExclusion(app: exclusion.app.rawValue, id: exclusion.id)
        await load()
    }
}

/// Settings → Release name tester: how Radarr or Sonarr reads a release name.
struct ParseView: View {
    let api: any ToolsAPI
    let apps: [ArrApp]
    @State private var app: ArrApp
    @State private var input = ""
    @State private var result: Loadable<ParseResult>?

    init(api: any ToolsAPI, apps: [ArrApp]) {
        self.api = api
        self.apps = apps
        _app = State(initialValue: apps.first ?? .radarr)
    }

    var body: some View {
        Form {
            Section {
                if apps.count > 1 {
                    Picker("App", selection: $app) {
                        ForEach(apps, id: \.self) { Text(Services.label($0.rawValue)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                TextField("Release name", text: $input, axis: .vertical)
                    .font(.caption.monospaced())
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                Button("Test") { Task { await run() } }
                    .disabled(input.trimmingCharacters(in: .whitespaces).count < 4)
            } footer: {
                Text("Paste a release name to see how Radarr or Sonarr reads it: the title, quality, custom formats and score, and where it would go.")
            }
            switch result {
            case nil: EmptyView()
            case .loading?: LoadingRow()
            case let .failed(reason)?: ErrorNote(reason)
            case let .loaded(parsed)?:
                Section {
                    if let match = parsed.match_title {
                        Label("Matches \(match) in the library", systemImage: "checkmark.circle.fill").foregroundStyle(Color.success)
                        ForEach(parsed.match_episodes ?? [], id: \.self) { Text(verbatim: $0).font(.caption).foregroundStyle(.secondary) }
                    } else {
                        Text("Nothing in the library matches it.").foregroundStyle(.secondary)
                    }
                }
                Section {
                    fact("Title", parsed.parsed_title)
                    fact("Year", parsed.year.map(String.init))
                    fact("Episode", parsed.episodeCode)
                    fact("Quality", parsed.quality)
                    fact("Languages", (parsed.languages ?? []).isEmpty ? nil : parsed.languages?.joined(separator: ", "))
                    fact("Release group", parsed.release_group)
                    fact("Edition", parsed.edition)
                    fact("Custom formats", (parsed.custom_formats ?? []).isEmpty ? nil : parsed.custom_formats?.joined(separator: ", "))
                    if !(parsed.custom_formats ?? []).isEmpty {
                        fact("Format score", String(parsed.custom_format_score ?? 0))
                    }
                }
            }
        }
        .themedList()
        .navigationTitle("Release name tester")
    }

    @ViewBuilder func fact(_ label: LocalizedStringKey, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(label) { Text(verbatim: value).multilineTextAlignment(.trailing) }
        }
    }

    func run() async {
        result = .loading
        do { result = .loaded(try await api.parse(app: app, title: input.trimmingCharacters(in: .whitespacesAndNewlines))) } catch {
            result = .failed(error.localizedDescription)
        }
    }
}
