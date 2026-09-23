import ArrdeckData
import SwiftUI

/// Interactive search: actual releases from the arr's indexers for one
/// title, season or episode, each grabbable. Rejected ones stay listed but
/// dimmed, with the first rejection reason — that is the useful part.
struct ReleasesSheet: View {
    @State private var model: ReleasesModel
    let title: String
    let dismiss: () -> Void

    init(target: ReleaseTarget, title: String, api: any ExtrasAPI, onSessionLost: @escaping @MainActor () -> Void, dismiss: @escaping () -> Void) {
        self.title = title
        self.dismiss = dismiss
        _model = State(initialValue: ReleasesModel(target: target, api: api, onSessionLost: onSessionLost))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    switch model.releases {
                    case .loading:
                        LoadingRow()
                        Text("Searching indexers… this can take a while").font(.caption).foregroundStyle(.secondary)
                    case let .failed(reason):
                        ErrorNote(reason)
                    case let .loaded(releases):
                        if releases.isEmpty { EmptyNote("No releases found") }
                        ForEach(releases, id: \.guid) { release in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(release.title).font(.subheadline.weight(.medium)).lineLimit(2)
                                    Text(details(release)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    if release.approved != true, let reason = release.rejections?.first {
                                        Text("rejected: \(reason)").font(.caption).foregroundStyle(.orange).lineLimit(2)
                                    }
                                }
                                Spacer(minLength: 0)
                                Button(model.grabbed.contains(release.guid) ? "Grabbed" : "Grab") {
                                    Task { await model.grab(release) }
                                }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                                .disabled(model.grabbed.contains(release.guid) || model.pending.contains(release.guid))
                            }
                            .opacity(release.approved == true ? 1 : 0.55)
                        }
                    }
                } header: {
                    Text(title)
                }
            }
            .navigationTitle("Interactive search")
            .toolbar { Button("Done") { dismiss() } }
            .task { await model.load() }
            .alert("Action failed", isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })) {
                Button("OK") { model.actionError = nil }
            } message: {
                Text(model.actionError ?? "")
            }
        }
    }

    func details(_ release: ArrRelease) -> String {
        var parts: [String] = []
        if let quality = release.quality { parts.append(quality) }
        parts.append(Format.bytes(release.size))
        parts.append("\(release.seeders.map(String.init) ?? "?")/\(release.leechers.map(String.init) ?? "?")")
        if let indexer = release.indexer { parts.append(indexer) }
        if let age = release.age_days { parts.append("\(Int(age.rounded()))d") }
        return parts.joined(separator: " · ")
    }
}

/// Files whose names drifted from the arr's naming scheme. Absent when
/// everything already matches, so its presence is the signal.
struct RenameCard: View {
    @State private var model: RenameModel

    init(ref: MediaRef, api: any ExtrasAPI, onSessionLost: @escaping @MainActor () -> Void) {
        _model = State(initialValue: RenameModel(ref: ref, api: api, onSessionLost: onSessionLost))
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
