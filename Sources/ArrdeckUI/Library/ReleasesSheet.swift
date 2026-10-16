import ArrdeckData
import SwiftUI

/// Interactive search: actual releases from the arr's indexers for one
/// title, season or episode, each grabbable. Sortable and filterable like the
/// web app's sheet; rejected ones stay listed, below the approved ones and
/// dimmed, with every reason the arr gave — that is the useful part.
struct ReleasesSheet: View {
    @State private var model: ReleasesModel
    let title: String
    let dismiss: () -> Void

    /// Kept between searches, as the web app keeps it, under the same name.
    @AppStorage("releases.sort") private var sort: ReleaseSort = .best
    @AppStorage(DisplayKeys.sizes) private var sizes: SizeStyle = .binary
    @State private var filters = ReleaseFilters()
    /// Typed as text, so a half-typed "1." survives; parsed into the filter.
    @State private var minGB = ""
    @State private var maxGB = ""

    init(target: ReleaseTarget, title: String, api: any ExtrasAPI, dismiss: @escaping () -> Void) {
        self.title = title
        self.dismiss = dismiss
        _model = State(initialValue: ReleasesModel(target: target, api: api))
    }

    var body: some View {
        NavigationStack {
            List {
                switch model.releases {
                case .loading:
                    Section {
                        LoadingRow()
                        Text("Searching indexers… this can take a while").font(.caption).foregroundStyle(.secondary)
                    } header: { Text(title) }
                case let .failed(reason):
                    Section { ErrorNote(reason) } header: { Text(title) }
                case let .loaded(releases):
                    if releases.isEmpty {
                        Section { EmptyNote("No releases found") } header: { Text(title) }
                    } else {
                        controls(releases)
                        let shown = ReleaseQuery.apply(releases, filters: filters, sort: sort)
                        Section {
                            if shown.isEmpty {
                                EmptyNote("No release matches the filters")
                            }
                            ForEach(shown, id: \.guid) { release in
                                row(release)
                            }
                        } header: {
                            Text(title)
                        } footer: {
                            Text("Showing \(shown.count) of \(releases.count)")
                        }
                    }
                }
            }
            .searchable(text: $filters.text, prompt: Text("Filter by title"))
            .navigationTitle("Interactive search")
            .toolbar { Button("Done") { dismiss() } }
            .task { await model.load() }
            .onChange(of: minGB) { _, text in filters.minBytes = ReleaseQuery.bytes(gb: text, style: sizes) }
            .onChange(of: maxGB) { _, text in filters.maxBytes = ReleaseQuery.bytes(gb: text, style: sizes) }
            .onChange(of: sizes) { _, _ in
                filters.minBytes = ReleaseQuery.bytes(gb: minGB, style: sizes)
                filters.maxBytes = ReleaseQuery.bytes(gb: maxGB, style: sizes)
            }
            .alert("Action failed", isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })) {
                Button("OK") { model.actionError = nil }
            } message: {
                Text(model.actionError ?? "")
            }
        }
        .outsideChrome()
    }

    /// Sort and the filters that only make sense once there is something to
    /// narrow: a quality or group menu appears when the results hold more than one.
    @ViewBuilder
    func controls(_ releases: [ArrRelease]) -> some View {
        let qualities = ReleaseQuery.distinctValues(releases, \.quality)
        let groups = ReleaseQuery.distinctValues(releases, \.release_group)
        Section {
            Picker("Sort by", selection: $sort) {
                ForEach(ReleaseSort.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            if qualities.count > 1 {
                Picker("Quality", selection: $filters.quality) {
                    Text("Any quality").tag("")
                    ForEach(qualities, id: \.self) { Text(verbatim: $0).tag($0) }
                }
            }
            if groups.count > 1 {
                Picker("Release group", selection: $filters.group) {
                    Text("Any group").tag("")
                    ForEach(groups, id: \.self) { Text(verbatim: $0).tag($0) }
                }
            }
            Toggle("Approved only", isOn: $filters.approvedOnly)
            HStack {
                Text("Size")
                Spacer()
                TextField("Min", text: $minGB).frame(width: 56)
                Text(verbatim: "–").foregroundStyle(.secondary)
                TextField("Max", text: $maxGB).frame(width: 56)
                Text(verbatim: "GB").foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.trailing)
            #if os(iOS)
            .keyboardType(.decimalPad)
            #endif
            if filters.isActive {
                Button("Clear filters") {
                    filters = ReleaseFilters()
                    minGB = ""
                    maxGB = ""
                }
            }
        }
    }

    func row(_ release: ArrRelease) -> some View {
        let rejected = ReleaseQuery.isRejected(release)
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Group {
                    Text(release.title).font(.subheadline.weight(.medium)).lineLimit(2)
                    Text(details(release)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    extras(release)
                }
                .opacity(rejected ? 0.55 : 1)
                if rejected, let reasons = release.rejections, !reasons.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Rejected").font(.caption.weight(.semibold))
                        ForEach(Array(reasons.enumerated()), id: \.offset) { _, reason in
                            Text(verbatim: "• \(reason)")
                        }
                    }
                    .font(.caption).foregroundStyle(Color.warning)
                }
            }
            Spacer(minLength: 0)
            Button(model.grabbed.contains(release.guid) ? "Grabbed" : "Grab") {
                Task { await model.grab(release) }
            }
            .buttonStyle(.borderedProminent).controlSize(.small)
            .disabled(model.grabbed.contains(release.guid) || model.pending.contains(release.guid))
        }
    }

    /// Release group, custom-format score, then the formats, languages and edition.
    @ViewBuilder
    func extras(_ release: ArrRelease) -> some View {
        let group = release.release_group.flatMap { $0.isEmpty ? nil : $0 }
        let score = ReleaseQuery.scoreText(release.custom_format_score)
        let tags = ReleaseQuery.tags(release)
        if group != nil || score != nil || !tags.isEmpty {
            HStack(spacing: 6) {
                if let group { Text(verbatim: group).fontWeight(.medium) }
                if let score, let value = release.custom_format_score {
                    Text(verbatim: score).fontWeight(.medium)
                        .foregroundStyle(value > 0 ? Color.success : Color.danger)
                        .accessibilityLabel(Text("Custom-format score \(score)"))
                }
                if !tags.isEmpty { Text(verbatim: tags.joined(separator: " · ")).lineLimit(2) }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    func details(_ release: ArrRelease) -> String {
        var parts: [String] = []
        if let quality = release.quality { parts.append(quality) }
        parts.append(Format.bytes(release.size))
        parts.append("\(release.seeders.map(String.init) ?? "?")/\(release.leechers.map(String.init) ?? "?")")
        if let indexer = release.indexer {
            parts.append(release._protocol.map { "\(indexer) (\($0))" } ?? indexer)
        }
        if let age = release.age_days { parts.append("\(Int(age.rounded()))d") }
        return parts.joined(separator: " · ")
    }
}

/// Files whose names drifted from the arr's naming scheme. Absent when
/// everything already matches, so its presence is the signal.
struct RenameCard: View {
    @State private var model: RenameModel

    init(ref: MediaRef, api: any ExtrasAPI) {
        _model = State(initialValue: RenameModel(ref: ref, api: api))
    }

    var body: some View {
        if !model.previews.isEmpty {
            Section("Rename files") {
                ForEach(model.previews.prefix(6), id: \.file_id) { preview in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preview.existing_path ?? "").font(.caption).foregroundStyle(.secondary).strikethrough().lineLimit(1)
                        Text(preview.new_path ?? "").font(.caption).lineLimit(1)
                    }
                }
                if model.previews.count > 6 {
                    Text("and \(model.previews.count - 6) more").font(.caption).foregroundStyle(.secondary)
                }
                Button("Rename \(model.previews.count) file(s)") { Task { await model.renameAll() } }
                    .disabled(model.busy)
            }
        } else {
            // Nothing to show; the task still has to run to find out.
            EmptyView().task { await model.load() }
        }
    }
}
