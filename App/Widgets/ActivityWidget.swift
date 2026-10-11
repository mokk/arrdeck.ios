import ArrdeckGlance
import SwiftUI
import UIKit
import WidgetKit

struct ActivityWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dk.thrawn.arrdeck.activity", provider: GlanceProvider()) { entry in
            ActivityView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(GlanceLink.activity.url)
        }
        .configurationDisplayName("Activity")
        .description("What arrived, failed or was grabbed lately, with today's first.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

/// What arrived lately, always the latest. Today's stands out: counted in
/// the accent colour, in bold with its time, outlined or in a section of its
/// own; anything older recedes with its day, but only beside something from
/// today — with nothing today the latest show as they are.
struct ActivityView: View {
    let entry: GlanceEntry
    @Environment(\.widgetFamily) private var family

    typealias Item = GlanceSnapshot.Activity.Entry

    var body: some View {
        let freshness = entry.freshness(.activity)
        if freshness == .expired || entry.snapshot?.activity == nil {
            OpenAppNote()
        } else if let activity = entry.snapshot?.activity {
            let stale = freshness == .stale
            Group {
                switch family {
                case .systemSmall: small(activity, stale: stale)
                case .systemLarge: large(activity, stale: stale)
                default: medium(activity, stale: stale)
                }
            }
            .staleness(freshness)
        }
    }

    func isToday(_ item: Item) -> Bool {
        Calendar.current.isDate(item.date, inSameDayAs: entry.date)
    }

    /// Whether `item` recedes: older than today while something came today.
    /// With nothing today, the latest shows as it is.
    func faded(_ item: Item, in activity: GlanceSnapshot.Activity) -> Bool {
        !isToday(item) && activity.entries.contains(where: isToday)
    }

    /// Everything that happened today, episodes counted one by one.
    func todayCount(_ activity: GlanceSnapshot.Activity) -> Int {
        activity.entries.filter(isToday).reduce(0) { $0 + $1.count }
    }

    // MARK: small

    /// The latest three as posters, today's outlined and in full colour, and
    /// the newest of them by name.
    func small(_ activity: GlanceSnapshot.Activity, stale: Bool) -> some View {
        let count = todayCount(activity)
        return VStack(alignment: .leading, spacing: 6) {
            if count > 0 {
                Label("\(count) today", systemImage: "arrow.down.circle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tint)
                    .lineLimit(1)
            } else {
                WidgetHeader(title: "Activity", symbol: "arrow.down.circle")
            }
            if let latest = activity.entries.first {
                HStack(spacing: 5) {
                    ForEach(activity.entries.prefix(3), id: \.self) { item in
                        poster(item, width: 42, today: isToday(item), faded: faded(item, in: activity))
                    }
                }
                Spacer(minLength: 0)
                let today = isToday(latest)
                Text(latest.title)
                    .font(.caption.weight(today ? .semibold : .medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    EventIcon(event: latest.event)
                    detail(latest).foregroundStyle(.secondary)
                    if stale {
                        UpdatedNote(at: activity.at)
                    } else {
                        when(latest, today: today)
                    }
                }
                .font(.caption2.weight(today ? .semibold : .regular))
                .lineLimit(1)
            } else {
                Spacer(minLength: 0)
                Text("No activity yet").font(.headline)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: medium

    func medium(_ activity: GlanceSnapshot.Activity, stale: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            header(activity, stale: stale)
            if activity.entries.isEmpty {
                Spacer(minLength: 0)
                Text("No activity yet").font(.headline)
                Spacer(minLength: 0)
            } else {
                ForEach(activity.entries.prefix(3), id: \.self) { item in
                    let today = isToday(item)
                    row(item, today: today, faded: faded(item, in: activity), posterWidth: 22,
                        titleFont: .caption.weight(today ? .semibold : .medium))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: large

    func large(_ activity: GlanceSnapshot.Activity, stale: Bool) -> some View {
        let shown = Array(activity.entries.prefix(5))
        let today = shown.filter(isToday)
        let earlier = shown.filter { !isToday($0) }
        return VStack(alignment: .leading, spacing: 8) {
            header(activity, stale: stale)
            if today.isEmpty {
                // nothing today: the latest, as they are
                ForEach(earlier, id: \.self) { item in
                    row(item, today: false, faded: false, posterWidth: 34, titleFont: .subheadline.weight(.medium))
                }
            } else {
                SectionLabel(title: "Today", emphasized: true)
                ForEach(today, id: \.self) { item in
                    row(item, today: true, faded: false, posterWidth: 34, titleFont: .subheadline.weight(.semibold))
                }
                if !earlier.isEmpty {
                    SectionLabel(title: "Earlier", emphasized: false).padding(.top, 2)
                    ForEach(earlier, id: \.self) { item in
                        row(item, today: false, faded: true, posterWidth: 26, titleFont: .caption.weight(.medium))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// A poster, a title over what happened, and when: today's time in the
    /// accent colour, and faded when older than something that came today.
    func row(_ item: Item, today: Bool, faded: Bool, posterWidth: CGFloat, titleFont: Font) -> some View {
        HStack(spacing: 10) {
            poster(item, width: posterWidth, today: today, faded: faded, outlined: false)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(titleFont).lineLimit(1)
                // a show's episodes, and what went wrong; a film that simply
                // arrived needs nothing under its title
                if hasSubtext(item) {
                    HStack(spacing: 4) {
                        EventIcon(event: item.event)
                        detail(item)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            when(item, today: today).font(.caption2.weight(today ? .semibold : .regular))
        }
        .opacity(faded ? 0.8 : 1)
    }

    /// Today's outlined in the accent where the posters stand alone (the
    /// small widget); faded ones desaturated.
    func poster(_ item: Item, width: CGFloat, today: Bool, faded: Bool, outlined: Bool = true) -> some View {
        PosterTile(item: item, width: width)
            .saturation(faded ? 0.35 : 1)
            .opacity(faded ? 0.7 : 1)
            .overlay {
                if today, outlined {
                    RoundedRectangle(cornerRadius: width * 0.16).strokeBorder(.tint, lineWidth: 2)
                }
            }
    }

    // MARK: pieces

    /// "Activity" with today's count in a badge, or the age once stale.
    func header(_ activity: GlanceSnapshot.Activity, stale: Bool) -> some View {
        HStack {
            WidgetHeader(title: "Activity", symbol: "arrow.down.circle")
            Spacer()
            if stale {
                UpdatedNote(at: activity.at)
            } else if case let count = todayCount(activity), count > 0 {
                Text("\(count) today")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.tint, in: Capsule())
            }
        }
    }

    /// A show's seasons and episodes ("S01E01–E08, S02E01–E08"), or how
    /// many when the numbers are unknown; nothing for a film, a book or an
    /// album, or for an arrival, the usual case. A failure or a grab says so.
    @ViewBuilder func detail(_ item: Item) -> some View {
        if item.kind == .episode, let code = item.code {
            Text(verbatim: code)
        } else if item.kind == .episode, item.count > 1 {
            Text("\(item.count) episodes")
        } else if item.event != .arrived {
            Text(eventLabel(item.event))
        }
    }

    func hasSubtext(_ item: Item) -> Bool {
        item.kind == .episode && (item.code != nil || item.count > 1) || item.event != .arrived
    }

    /// Today's time in the accent colour, an older day plainly.
    @ViewBuilder func when(_ item: Item, today: Bool) -> some View {
        if today {
            Text(item.date, style: .time).foregroundStyle(.tint)
        } else {
            day(item).foregroundStyle(.secondary)
        }
    }

    /// "Yesterday", a weekday within the week, a date before that.
    @ViewBuilder func day(_ item: Item) -> some View {
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: item.date),
                                           to: calendar.startOfDay(for: entry.date)).day ?? 0
        if days == 1 {
            Text("Yesterday")
        } else if days < 7 {
            Text(item.date, format: .dateTime.weekday(.wide))
        } else {
            Text(item.date, format: .dateTime.day().month(.abbreviated))
        }
    }

    func eventLabel(_ event: Item.Event) -> LocalizedStringKey {
        switch event {
        case .arrived: ""
        case .failed: "Failed"
        case .grabbed: "Grabbed"
        }
    }
}

/// What went otherwise than arriving, as a coloured symbol: failed, grabbed.
struct EventIcon: View {
    let event: GlanceSnapshot.Activity.Entry.Event

    var body: some View {
        switch event {
        // the usual case: no mark
        case .arrived:
            EmptyView()
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .accessibilityLabel(Text("Failed"))
        case .grabbed:
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
                .accessibilityLabel(Text("Grabbed"))
        }
    }
}

/// "TODAY" in the accent colour, "EARLIER" in grey.
struct SectionLabel: View {
    let title: LocalizedStringKey
    let emphasized: Bool

    var body: some View {
        Text(title)
            .font(.caption2.weight(.bold))
            .textCase(.uppercase)
            .foregroundStyle(emphasized ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
    }
}

/// The title's poster from the shared container, or a coloured tile with
/// what it is (an album, or a poster not fetched yet).
struct PosterTile: View {
    let item: GlanceSnapshot.Activity.Entry
    let width: CGFloat

    var image: UIImage? {
        guard item.hasPoster, let key = item.key, let url = GlanceStore().posterURL(key) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    /// The app's placeholder colour for the same title.
    var hue: Double {
        Double(item.title.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
    }

    var symbol: String {
        switch item.kind {
        case .movie: "film"
        case .episode: "tv"
        case .book: "book.closed"
        case .album: "music.note"
        }
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color(hue: hue, saturation: 0.45, brightness: 0.55)
                    Image(systemName: symbol).font(.system(size: width * 0.4)).foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .frame(width: width, height: width * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: width * 0.16))
        .accessibilityHidden(true)
    }
}
