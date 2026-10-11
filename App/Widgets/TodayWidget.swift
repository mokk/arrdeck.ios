import ArrdeckGlance
import SwiftUI
import WidgetKit

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dk.thrawn.arrdeck.today", provider: GlanceProvider()) { entry in
            TodayView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(GlanceLink.calendar.url)
        }
        .configurationDisplayName("Today")
        .description("The episodes, films and books that come out today.")
        .supportedFamilies([.systemMedium, .accessoryRectangular])
    }
}

struct TodayView: View {
    let entry: GlanceEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let freshness = entry.freshness(.today)
        if freshness == .expired || entry.snapshot?.today == nil {
            OpenAppNote()
        } else if let today = entry.snapshot?.today {
            Group {
                if family == .accessoryRectangular { rectangular(today) } else { medium(today, stale: freshness == .stale) }
            }
            .staleness(freshness)
        }
    }

    func rectangular(_ today: GlanceSnapshot.Today) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Label("Today", systemImage: "calendar").font(.headline).widgetAccentable()
            if today.entries.isEmpty {
                Text("Nothing out today").font(.caption)
            }
            ForEach(today.entries.prefix(2), id: \.self) { entry in
                Text(line(entry)).font(.caption).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func medium(_ today: GlanceSnapshot.Today, stale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                WidgetHeader(title: "Today", symbol: "calendar")
                Spacer()
                if stale { UpdatedNote(at: today.at) }
            }
            if today.entries.isEmpty {
                Spacer(minLength: 0)
                Text("Nothing out today").font(.headline)
                Spacer(minLength: 0)
            } else {
                ForEach(today.entries, id: \.self) { entry in
                    HStack(spacing: 8) {
                        Group {
                            if let time = entry.time {
                                Text(time, style: .time)
                            } else {
                                Text(kindLabel(entry.kind))
                            }
                        }
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .leading)
                        Text(entry.title).font(.caption.weight(.medium)).lineLimit(1)
                        if let code = entry.code {
                            Text(verbatim: code).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                .layoutPriority(-1)
                        }
                        Spacer(minLength: 0)
                        if entry.downloaded {
                            Image(systemName: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
                                .accessibilityLabel(Text("Downloaded"))
                        }
                    }
                }
                if today.count > today.entries.count {
                    Text("\(today.count - today.entries.count) more")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    func kindLabel(_ kind: GlanceSnapshot.Today.Entry.Kind) -> LocalizedStringKey {
        switch kind {
        case .movie: "Film"
        case .book: "Book"
        case .album: "Album"
        case .episode: "Episode"
        }
    }

    /// One line for the Lock Screen: "Slow Horses S06E05".
    func line(_ entry: GlanceSnapshot.Today.Entry) -> String {
        [entry.title, entry.code].compactMap { $0 }.joined(separator: " ")
    }
}
