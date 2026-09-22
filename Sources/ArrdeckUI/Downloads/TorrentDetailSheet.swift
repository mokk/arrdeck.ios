import ArrdeckData
import SwiftUI

/// Per-torrent detail: the actions the list's swipe offers plus recheck, and
/// what the client knows — files and trackers. Limits, queue position,
/// category and tags follow later.
struct TorrentDetailSheet: View {
    let torrent: Torrent
    let model: DownloadsModel
    let dismiss: () -> Void

    @State private var details: Loadable<TorrentDetails> = .loading
    @State private var confirmingDelete = false

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
                do { details = .loaded(try await model.details(for: torrent)) }
                catch { details = .failed((error as? APIError)?.description ?? error.localizedDescription) }
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
