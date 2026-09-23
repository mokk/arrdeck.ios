import ArrdeckData
import SwiftUI

/// Per-torrent detail: the actions the list's swipe offers plus recheck,
/// speed limits, queue position, category and tags, and what the client
/// knows — files and trackers.
struct TorrentDetailSheet: View {
    let torrent: Torrent
    let model: DownloadsModel
    let dismiss: () -> Void
    @State private var extras: TorrentExtrasModel

    @State private var details: Loadable<TorrentDetails> = .loading
    @State private var confirmingDelete = false

    init(torrent: Torrent, model: DownloadsModel, api: any ExtrasAPI, onSessionLost: @escaping @MainActor () -> Void, dismiss: @escaping () -> Void) {
        self.torrent = torrent
        self.model = model
        self.dismiss = dismiss
        _extras = State(initialValue: TorrentExtrasModel(torrent: torrent, api: api, onSessionLost: onSessionLost))
    }

    var subtitle: String {
        var parts = [Services.label(torrent.client.rawValue), Format.bytes(torrent.size)]
        parts.append("ratio \(torrent.ratio.map { $0.formatted(.number.precision(.fractionLength(2))) } ?? "—")")
        parts.append("added \(Format.epochDay(torrent.added_on))")
        if let tracker = torrent.tracker { parts.append(tracker) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(torrent.name).font(.headline)
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            StateBadge(state: torrent.state)
                            if torrent.dl_speed > 0 || torrent.ul_speed > 0 {
                                Text("↓\(Format.speed(torrent.dl_speed)) ↑\(Format.speed(torrent.ul_speed))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        ProgressBar(value: torrent.progress)
                    }
                }

                Section {
                    if confirmingDelete {
                        Button("Delete torrent and files", role: .destructive) {
                            Task { await model.delete(torrent, deleteData: true); dismiss() }
                        }
                        Button("Delete torrent only", role: .destructive) {
                            Task { await model.delete(torrent, deleteData: false); dismiss() }
                        }
                        Button("Back") { confirmingDelete = false }
                    } else {
                        Button(torrent.isPaused ? "Resume" : "Pause") {
                            Task { await model.togglePaused(torrent); dismiss() }
                        }
                        Button("Recheck") { Task { await model.recheck(torrent) } }
                        Button("Delete…", role: .destructive) { confirmingDelete = true }
                    }
                }
                .disabled(model.isPending(torrent.key))

                switch details {
                case .loading:
                    Section { LoadingRow() }
                case let .failed(reason):
                    Section { ErrorNote(reason) }
                case let .loaded(detail):
                    extrasSections
                    Section("Files (\(detail.files.count))") {
                        ForEach(Array(detail.files.enumerated()), id: \.offset) { _, file in
                            FileRow(file: file)
                        }
                    }
                    if let trackers = detail.trackers, !trackers.isEmpty {
                        Section("Trackers") {
                            ForEach(Array(trackers.enumerated()), id: \.offset) { _, tracker in
                                HStack(spacing: 8) {
                                    Circle().fill(tracker.ok == false ? .red : .green).frame(width: 6, height: 6)
                                    Text(tracker.host).font(.caption).lineLimit(1)
                                    Spacer()
                                    if tracker.ok == false, let message = tracker.message {
                                        Text(message).font(.caption).foregroundStyle(.red).lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Torrent")
            .toolbar { Button("Done") { dismiss() } }
            .task {
                do {
                    let loaded = try await model.details(for: torrent)
                    extras.apply(loaded)
                    details = .loaded(loaded)
                } catch {
                    details = .failed((error as? APIError)?.description ?? error.localizedDescription)
                }
                await extras.loadTags()
            }
            .alert("Action failed", isPresented: Binding(get: { extras.actionError != nil }, set: { if !$0 { extras.actionError = nil } })) {
                Button("OK") { extras.actionError = nil }
            } message: {
                Text(extras.actionError ?? "")
            }
        }
    }

    @ViewBuilder var extrasSections: some View {
        Section("Speed limits") {
            HStack {
                Text("Down (KiB/s, 0 = ∞)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                TextField("0", text: $extras.downloadKiB).multilineTextAlignment(.trailing).frame(width: 90)
            }
            HStack {
                Text("Up (KiB/s, 0 = ∞)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                TextField("0", text: $extras.uploadKiB).multilineTextAlignment(.trailing).frame(width: 90)
            }
            Button("Apply") { Task { await extras.saveLimits() } }
                .disabled(!extras.limitsDirty || extras.busy)
        }
        Section("Queue") {
            HStack {
                ForEach(QueuePosition.allCases, id: \.self) { position in
                    Button(position.label) { Task { await extras.move(position) } }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                if extras.isQbit {
                    Button("Force start") { Task { await extras.forceStart() } }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            .disabled(extras.busy)
        }
        if extras.isQbit, !extras.categories.isEmpty {
            Section {
                Picker("Category", selection: Binding(
                    get: { extras.category ?? "" },
                    set: { value in Task { await extras.setCategory(value) } }
                )) {
                    Text("(none)").tag("")
                    ForEach(extras.categories, id: \.self) { Text($0).tag($0) }
                }
                .disabled(extras.busy)
            }
        }
        if extras.isQbit, !extras.allTags.isEmpty {
            Section("Tags") {
                // One button per tag, flipping between applying and removing.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(extras.allTags, id: \.self) { tag in
                            Button(tag) { Task { await extras.toggle(tag: tag) } }
                                .buttonStyle(.bordered).controlSize(.small)
                                .tint(extras.tags.contains(tag) ? .accentColor : .secondary)
                        }
                    }
                }
                .disabled(extras.busy)
            }
        }
    }
}

struct FileRow: View {
    let file: TorrentFile

    var skipped: Bool { file.wanted == false }
    var summary: String {
        let percent = Int((file.progress * 100).rounded())
        return "\(Format.bytes(file.size)) · \(percent)%"
    }

    var body: some View {
        HStack {
            Image(systemName: skipped ? "square" : "checkmark.square.fill")
                .foregroundStyle(skipped ? Color.secondary : Color.accentColor)
            Text(file.name)
                .font(.caption)
                .lineLimit(1)
                .strikethrough(skipped)
                .foregroundStyle(skipped ? Color.secondary : Color.primary)
            Spacer()
            Text(summary).font(.caption).foregroundStyle(.secondary)
        }
    }
}
