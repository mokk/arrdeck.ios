import ArrdeckData
import SwiftUI

/// The PWA's calendar: a month grid or week strip with dots per day, or a
/// fortnight's agenda grouped by day. Tapping a day narrows the list below.
public struct CalendarScreen: View {
    @State private var model: CalendarModel

    public init(api: any CalendarAPI, onSessionLost: @escaping @MainActor () -> Void) {
        _model = State(initialValue: CalendarModel(api: api, onSessionLost: onSessionLost))
    }

    public var body: some View {
        List {
            Section {
                Picker("View", selection: $model.view) {
                    ForEach(CalendarView.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                HStack {
                    Text(heading).font(.headline)
                    Spacer()
                    // the agenda is always "from today", so stepping it makes no sense
                    if model.view != .agenda {
                        Button { model.step(-1) } label: { Image(systemName: "chevron.left") }
                            .buttonStyle(.bordered).controlSize(.small)
                            .accessibilityLabel("Previous")
                        Button { model.step(1) } label: { Image(systemName: "chevron.right") }
                            .buttonStyle(.bordered).controlSize(.small)
                            .accessibilityLabel("Next")
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                if model.view == .month {
                    monthGrid.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                } else if model.view == .week {
                    weekStrip.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                }
            }

            ForEach(ArrApp.allCases, id: \.self) { app in
                if let reason = model.offlineReason(app) {
                    Section { ErrorNote("\(Services.label(app.rawValue)) offline — \(reason)") }
                }
            }

            switch model.blocks {
            case .loading:
                Section { LoadingRow() }
            case let .failed(reason):
                Section { ErrorNote(reason) }
            case .loaded:
                if model.view == .agenda {
                    // grouped by day rather than one flat list, so the next
                    // fortnight reads as a schedule instead of a wall of rows
                    if model.days.isEmpty {
                        Section { EmptyNote("Nothing scheduled") }
                    }
                    ForEach(model.days, id: \.self) { day in
                        Section {
                            ForEach(Array((model.byDay[day] ?? []).enumerated()), id: \.offset) { _, item in
                                CalendarRow(item: item, showDate: false)
                            }
                        } header: {
                            HStack {
                                Text(dayHeading(day))
                                if day == model.today { Text("today").foregroundStyle(Color.accentColor) }
                            }
                        }
                    }
                } else {
                    Section {
                        if model.listed.isEmpty { EmptyNote("Nothing scheduled") }
                        ForEach(Array(model.listed.enumerated()), id: \.offset) { _, item in
                            CalendarRow(item: item, showDate: model.selectedDay == nil)
                        }
                    }
                }
            }
        }
        .dashboardListStyle()
        .navigationTitle("Calendar")
        .task { await model.load() }
        .refreshable { await model.load() }
        .accessibilityIdentifier("calendar")
    }

    var heading: String {
        let range = model.range
        switch model.view {
        case .month:
            return range.start.formatted(.dateTime.month(.wide).year()).capitalized
        case .week:
            let end = range.day(6)
            return "\(range.start.formatted(.dateTime.day().month(.abbreviated))) – \(end.formatted(.dateTime.day().month(.abbreviated)))"
        case .agenda:
            return "Next \(CalendarRange.agendaDays) days"
        }
    }

    func dayHeading(_ iso: String) -> String {
        guard let date = Format.parseDate(iso) else { return iso }
        return date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)).capitalized
    }

    var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 4), count: 7) }

    var monthGrid: some View {
        let range = model.range
        let leading = (Calendar.current.component(.weekday, from: range.start) + 5) % 7
        return LazyVGrid(columns: columns, spacing: 4) {
            ForEach(0..<leading, id: \.self) { _ in Color.clear.frame(height: 56) }
            ForEach(0..<range.days, id: \.self) { index in
                dayCell(range.day(index), tall: true)
            }
        }
        .padding(.vertical, 4)
    }

    var weekStrip: some View {
        let range = model.range
        return LazyVGrid(columns: columns, spacing: 4) {
            ForEach(0..<7, id: \.self) { index in dayCell(range.day(index), tall: false) }
        }
        .padding(.vertical, 4)
    }

    func dayCell(_ date: Date, tall: Bool) -> some View {
        let iso = CalendarRange.isoDay(date)
        let items = model.byDay[iso] ?? []
        let isToday = iso == model.today
        let selected = model.selectedDay == iso
        return Button {
            model.toggle(day: iso)
        } label: {
            VStack(spacing: 3) {
                if !tall {
                    Text(date.formatted(.dateTime.weekday(.abbreviated))).font(.system(size: 9)).textCase(.uppercase).foregroundStyle(.secondary)
                }
                Text(date.formatted(.dateTime.day()))
                    .font(.caption.weight(isToday ? .bold : .regular))
                    .foregroundStyle(isToday ? Color.accentColor : Color.primary)
                HStack(spacing: 2) {
                    ForEach(Array(items.prefix(4).enumerated()), id: \.offset) { _, item in
                        Circle().fill(dotColor(item)).frame(width: 5, height: 5)
                    }
                }
                .frame(height: 6)
            }
            .frame(maxWidth: .infinity, minHeight: tall ? 56 : 64)
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        // the coloured dots alone don't say how much is on a day
        .accessibilityLabel("\(date.formatted(.dateTime.weekday(.wide).day().month(.wide))) — \(items.count) scheduled")
    }

    func dotColor(_ item: CalendarItem) -> Color {
        if item.has_file == true { return .green }
        return item.app == .radarr ? .orange : .blue
    }
}

struct CalendarRow: View {
    let item: CalendarItem
    let showDate: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.subheadline.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    StateBadge(state: item.app.rawValue)
                    if let kind = item.release_type { StateBadge(state: kind.capitalized) }
                    Text(item.extra ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                if showDate { Text(Format.day(item.date)).font(.caption).foregroundStyle(.secondary) }
                if item.has_file == true { StateBadge(state: "downloaded") }
            }
        }
    }
}
