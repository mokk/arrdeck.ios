import ArrdeckGlance
import SwiftUI
import WidgetKit

struct GlanceEntry: TimelineEntry {
    let date: Date
    /// nil: no shared container, nothing written yet, or a file from another build.
    let snapshot: GlanceSnapshot?

    func freshness(_ section: GlanceSnapshot.Section) -> Freshness {
        snapshot?.freshness(section, now: date) ?? .expired
    }
}

/// One timeline per snapshot. The app reloads the widgets when it writes;
/// between writes, the entries already scheduled here dim the numbers and
/// then withdraw them as they age, because nothing else will run.
struct GlanceProvider: TimelineProvider {
    func placeholder(in context: Context) -> GlanceEntry {
        GlanceEntry(date: .now, snapshot: .sample(.now))
    }

    func getSnapshot(in context: Context, completion: @escaping (GlanceEntry) -> Void) {
        let stored = GlanceStore().read()
        // the widget gallery shows what the widget looks like with data
        completion(GlanceEntry(date: .now, snapshot: context.isPreview && stored == nil ? .sample(.now) : stored))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GlanceEntry>) -> Void) {
        let now = Date.now
        guard let snapshot = GlanceStore().read() else {
            // nothing will change until the app writes and reloads
            completion(Timeline(entries: [GlanceEntry(date: now, snapshot: nil)], policy: .never))
            return
        }
        let moments = [now] + snapshot.transitions(after: now)
        completion(Timeline(entries: moments.map { GlanceEntry(date: $0, snapshot: snapshot) }, policy: .never))
    }
}

extension GlanceSnapshot {
    /// For the gallery and placeholders.
    static func sample(_ now: Date) -> GlanceSnapshot {
        GlanceSnapshot(
            server: "arrdeck",
            downloads: Downloads(
                at: now,
                top: [
                    .init(name: "Slow Horses", progress: 0.62, speed: 6_400_000, eta: 540),
                    .init(name: "Dune Part Two", progress: 0.18, speed: 3_100_000, eta: 2900),
                ],
                count: 2, speed: 9_500_000, progress: 0.34, eta: 2900
            ),
            today: Today(
                at: now, day: GlanceDay.iso(now),
                entries: [
                    .init(kind: .episode, title: "Slow Horses", code: "S06E05", time: now),
                    .init(kind: .movie, title: "Street Fighter"),
                ],
                count: 2
            ),
            disk: Disk(at: now, free: 1_052_684_484_608, total: nil, label: "radarr"),
            activity: Activity(at: now, entries: [
                .init(kind: .episode, event: .arrived, title: "Slow Horses", code: "S06E05", date: now.addingTimeInterval(-1800)),
                .init(kind: .movie, event: .arrived, title: "Animals", date: now.addingTimeInterval(-7200)),
                .init(kind: .episode, event: .arrived, title: "Mayfair Witches", code: "S02E02–E08", count: 7,
                      date: now.addingTimeInterval(-26 * 3600)),
            ])
        )
    }
}
