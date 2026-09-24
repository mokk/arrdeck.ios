import ArrdeckData
import SwiftUI

/// The calendar as one list, opened at today: a big date per day with how far
/// away it is, a divider per month, and each entry with its cover, its app's
/// colour, the air time and what kind of day it is — a finale, a release, on disk.
public struct CalendarScreen: View {
    @State private var model: CalendarModel
    @State private var opened = false
    @AppStorage(DisplayKeys.spoilers) private var spoilers: Spoilers = .off
    let api: any CalendarAPI & LibraryPageAPI
    let baseURL: URL
    let hasPlex: Bool
    let onSessionLost: @MainActor () -> Void

    public init(api: any CalendarAPI & LibraryPageAPI, baseURL: URL, hasPlex: Bool, onSessionLost: @escaping @MainActor () -> Void) {
        _model = State(initialValue: CalendarModel(api: api, onSessionLost: onSessionLost))
        self.api = api
        self.baseURL = baseURL
        self.hasPlex = hasPlex
        self.onSessionLost = onSessionLost
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    filters.padding(.bottom, 12)
                    ForEach(ArrApp.allCases, id: \.self) { app in
                        if let reason = model.offlineReason(app) {
                            ErrorNote("\(Services.label(app.rawValue)) offline — \(reason)").padding(.bottom, 8)
                        }
                    }
                    switch model.blocks {
                    case .loading: LoadingRow()
                    case let .failed(reason): ErrorNote(reason)
                    case .loaded:
                        Button("Show earlier") { Task { await model.showEarlier() } }
                            .font(.subheadline).frame(maxWidth: .infinity).padding(.bottom, 8)
                        ForEach(Array(model.days.enumerated()), id: \.element.day) { index, day in
                            if index == 0 || month(of: model.days[index - 1].day) != month(of: day.day) {
                                MonthDivider(title: month(of: day.day))
                            }
                            DaySection(day: day.day, entries: day.entries, today: model.today,
                                       baseURL: baseURL, hideEpisodeTitles: spoilers != .off)
                                .id(day.day)
                        }
                        Button("Show later") { Task { await model.showLater() } }
                            .font(.subheadline).frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .background(Color.grouped)
            .navigationTitle("Calendar")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Today") { withAnimation { proxy.scrollTo(model.today, anchor: .top) } }
                }
            }
            .onChange(of: model.blocks.value == nil) { _, missing in
                // once, when the list first has something to scroll through
                guard !missing, !opened else { return }
                opened = true
                Task { @MainActor in proxy.scrollTo(model.today, anchor: .top) }
            }
        }
        .navigationDestination(for: MediaRef.self) { ref in
            MediaDestination(ref: ref, api: api, baseURL: baseURL, hasPlex: hasPlex, onSessionLost: onSessionLost)
        }
        .task { await model.load() }
        .refreshable { await model.load() }
        .accessibilityIdentifier("calendar")
    }

    func month(of iso: String) -> String {
        CalendarDay.date(iso).map { $0.formatted(.dateTime.month(.wide).year()) } ?? ""
    }

    /// Movies / Shows / Books to leave out, and whether to hide what is on disk.
    var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if model.apps.count > 1 {
                    ForEach(model.apps, id: \.self) { app in
                        let on = !model.hiddenApps.contains(app)
                        FilterChip(label: appLabel(app), on: on, dot: CalendarColors.stripe(app)) {
                            if on { model.hiddenApps.insert(app) } else { model.hiddenApps.remove(app) }
                        }
                    }
                }
                FilterChip(label: String(localized: "Hide downloaded"), on: model.hideDownloaded) {
                    model.hideDownloaded.toggle()
                }
            }
        }
    }

    func appLabel(_ app: ArrApp) -> String {
        switch app {
        case .radarr: String(localized: "Movies")
        case .sonarr: String(localized: "Shows")
        case .readarr: String(localized: "Books")
        }
    }
}

/// The theme's colours for each app's stripe, so a palette recolours them too.
enum CalendarColors {
    @MainActor static func stripe(_ app: ArrApp) -> Color {
        switch app {
        case .radarr: Color.warning
        case .sonarr: Color.accent
        case .readarr: Color.success
        }
    }
}

private struct MonthDivider: View {
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Text(title.uppercased()).font(.caption.weight(.bold)).tracking(1.5).foregroundStyle(.secondary)
            Rectangle().fill(.quaternary).frame(height: 1)
        }
        .padding(.top, 14).padding(.bottom, 10)
    }
}

private struct DaySection: View {
    let day: String
    let entries: [CalendarEntry]
    let today: String
    let baseURL: URL
    let hideEpisodeTitles: Bool

    var date: Date { CalendarDay.date(day) ?? .now }
    var isToday: Bool { day == today }

    var relative: String {
        let start = Calendar.current.startOfDay(for: .now)
        let days = Calendar.current.dateComponents([.day], from: start, to: date).day ?? 0
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        let text = formatter.localizedString(from: DateComponents(day: days))
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Text(date.formatted(.dateTime.weekday(.abbreviated)).uppercased()).font(.system(size: 10, weight: .semibold))
                Text(date.formatted(.dateTime.day())).font(.title3.weight(.heavy))
            }
            .frame(width: 48)
            .padding(.vertical, 6)
            .background(isToday ? Color.accent : Color.card, in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(isToday ? Color.white : Color.primary)
            VStack(alignment: .leading, spacing: 6) {
                Text(relative).font(.caption.weight(.semibold)).foregroundStyle(isToday ? Color.accent : Color.secondary)
                if entries.isEmpty {
                    Text("Nothing today").font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(Color.card, in: RoundedRectangle(cornerRadius: 12))
                }
                ForEach(entries) { entry in
                    if let ref = entry.item.ref {
                        NavigationLink(value: ref) { EntryRow(entry: entry, baseURL: baseURL, hideEpisodeTitle: hideEpisodeTitles) }
                            .buttonStyle(.plain)
                    } else {
                        EntryRow(entry: entry, baseURL: baseURL, hideEpisodeTitle: hideEpisodeTitles)
                    }
                }
            }
        }
        .padding(.bottom, 14)
        .opacity(day < today ? 0.6 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(date.formatted(.dateTime.weekday(.wide).day().month(.wide))))
    }
}

private struct EntryRow: View {
    let entry: CalendarEntry
    let baseURL: URL
    let hideEpisodeTitle: Bool

    var item: CalendarItem { entry.item }

    var subtitle: String? {
        guard item.app == .sonarr else { return item.extra }
        var parts = [entry.code].compactMap { $0 }
        if entry.count > 1 {
            parts.append(String(localized: "\(entry.count) episodes"))
        } else if !hideEpisodeTitle, let title = entry.episodeTitle {
            parts.append(title)
        }
        return parts.joined(separator: " · ")
    }

    var time: String? {
        guard item.app == .sonarr, let raw = item.date, let date = Format.parseDate(raw) else { return nil }
        return date.formatted(date: .omitted, time: .shortened)
    }

    var finale: String? { FinaleLabel.text(item.finale_type) }

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(CalendarColors.stripe(ArrApp(rawValue: item.app.rawValue) ?? .sonarr)).frame(width: 4)
            Poster(path: item.poster, baseURL: baseURL, width: 34, cornerRadius: 5, title: item.title)
                .padding(.vertical, 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(verbatim: subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 4) {
                    if let finale { Pill(text: finale, color: Color.accent) }
                    if let kind = item.release_type { Pill(text: kind.capitalized, color: Color.warning) }
                    if item.has_file == true { Pill(text: String(localized: "On disk"), color: Color.success) }
                }
            }
            Spacer(minLength: 0)
            if let time { Text(time).font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary).padding(.trailing, 10) }
        }
        .background(Color.card, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }
}

private struct Pill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text).font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(color)
    }
}

struct FilterChip: View {
    let label: String
    let on: Bool
    var dot: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
                Text(label).font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(on ? Color.accent : Color.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(on ? Color.white : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
