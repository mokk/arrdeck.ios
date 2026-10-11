import ArrdeckData
import ArrdeckGlance
import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// The library titles the app has loaded, by title: what the Activity widget
/// calls a history row (the library's name, not the release's) and where its
/// poster is. Every library tab loads at launch, so this fills soon after.
@MainActor @Observable
final class LibraryTitles {
    static let shared = LibraryTitles()

    private(set) var titles: [MediaRef: GlanceTitle] = [:]

    /// One library's rows, replacing what it had before.
    func record(_ rows: [LibraryRow], app: LibraryApp) {
        var next = titles.filter { $0.key.app != app.arr }
        for row in rows { next[row.ref] = GlanceTitle(title: row.title, poster: row.poster) }
        guard next != titles else { return }
        titles = next
    }
}

/// Small poster copies in the widgets' container, for the Activity widget —
/// it cannot fetch anything itself. Each is fetched once; one that failed is
/// not tried again this run, so a missing image costs one request, not one
/// a poll.
@MainActor @Observable
final class GlancePosters {
    static let shared = GlancePosters()

    /// The keys with a file on disk. Watched: a poster landing re-publishes
    /// the snapshot, so its entry starts showing it.
    private(set) var stored: Set<String> = []
    @ObservationIgnored private var fetching: Set<String> = []
    @ObservationIgnored private var failed: Set<String> = []
    @ObservationIgnored private let store = GlanceStore()

    /// A poster's size in the widget, at 3x: the extension's memory is tight.
    static let size = CGSize(width: 108, height: 162)

    init() {
        guard let directory = store.postersURL else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        stored = Set(names.filter { $0.hasSuffix(".jpg") }.map { String($0.dropLast(4)) })
    }

    /// Fetches what these entries are missing, from the library's poster
    /// paths, and drops the files no entry shows any more.
    func update(for entries: [GlanceSnapshot.Activity.Entry], titles: [MediaRef: GlanceTitle], baseURL: URL) {
        let wanted = Set(entries.compactMap(\.key))
        for entry in entries where !entry.hasPoster {
            guard let key = entry.key, !stored.contains(key), !fetching.contains(key), !failed.contains(key),
                  let path = titles.first(where: { $0.key.glanceKey == key })?.value.poster,
                  let url = URL(string: path, relativeTo: baseURL), let file = store.posterURL(key)
            else { continue }
            fetching.insert(key)
            Task {
                let saved = await Self.fetch(url, to: file)
                fetching.remove(key)
                if saved { stored.insert(key) } else { failed.insert(key) }
            }
        }
        prune(keeping: wanted)
    }

    private func prune(keeping wanted: Set<String>) {
        for key in stored.subtracting(wanted).subtracting(fetching) {
            if let file = store.posterURL(key) { try? FileManager.default.removeItem(at: file) }
            stored.remove(key)
        }
    }

    /// Off the main actor: the download, the resize and the write. The shared
    /// session, so the sign-in cookie goes along as it does for the app's own
    /// posters.
    nonisolated private static func fetch(_ url: URL, to file: URL) async -> Bool {
        #if canImport(UIKit)
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
              let image = UIImage(data: data),
              let thumbnail = await image.byPreparingThumbnail(ofSize: size),
              let jpeg = thumbnail.jpegData(compressionQuality: 0.8)
        else { return false }
        // atomic: the widget may read it mid-write
        return (try? jpeg.write(to: file, options: [.atomic])) != nil
        #else
        return false
        #endif
    }
}
