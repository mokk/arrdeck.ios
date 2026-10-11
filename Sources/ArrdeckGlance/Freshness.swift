import Foundation

/// How much a section of the snapshot can still be trusted. Only the app
/// writes the snapshot, so once it is closed every number ages: first it is
/// shown with the time it was taken, then not at all — download progress
/// from yesterday is junk, not information.
public enum Freshness: Sendable, Equatable {
    /// Shown as is.
    case fresh
    /// Shown, dimmed, with "Updated 14:05".
    case stale
    /// Not shown: "Open arrdeck to load".
    case expired
}

extension GlanceSnapshot {
    public enum Section: CaseIterable, Sendable {
        case downloads, today, disk, activity
    }

    /// After how long a section turns stale, and after how long it expires.
    /// Torrents move by the second; free space by the day.
    public static func limits(_ section: Section) -> (stale: TimeInterval, expired: TimeInterval) {
        switch section {
        case .downloads: (10 * 60, 2 * 3600)
        // the day's list changes only when something is added to it
        case .today: (6 * 3600, 24 * 3600)
        case .disk: (12 * 3600, 7 * 24 * 3600)
        // what happened stays true; only what came since is missing
        case .activity: (6 * 3600, 3 * 24 * 3600)
        }
    }

    func at(_ section: Section) -> Date? {
        switch section {
        case .downloads: downloads?.at
        case .today: today?.at
        case .disk: disk?.at
        case .activity: activity?.at
        }
    }

    /// nil when the section was never written.
    public func freshness(_ section: Section, now: Date, calendar: Calendar = .current) -> Freshness? {
        guard let at = at(section) else { return nil }
        // yesterday's list is not today's, however recently it was written
        if section == .today, today?.day != GlanceDay.iso(now, calendar: calendar) { return .expired }
        let age = now.timeIntervalSince(at)
        let limits = Self.limits(section)
        // a clock moved backwards since: the age means nothing, so trust nothing
        if age < -60 { return .expired }
        if age >= limits.expired { return .expired }
        return age >= limits.stale ? .stale : .fresh
    }

    /// The moments after `now` at which a section changes state, earliest
    /// first. The widget's timeline gets an entry at each: a widget is not
    /// asked again when the app stops writing, so the dimming and the
    /// "Open arrdeck" state have to be scheduled up front.
    public func transitions(after now: Date, calendar: Calendar = .current) -> [Date] {
        var moments: Set<Date> = []
        for section in Section.allCases {
            guard let at = at(section) else { continue }
            let limits = Self.limits(section)
            moments.insert(at.addingTimeInterval(limits.stale))
            moments.insert(at.addingTimeInterval(limits.expired))
        }
        // at midnight today's list expires and Activity's "today" moves on
        if today != nil || activity != nil, let midnight = calendar.nextDate(
            after: now, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime
        ) {
            moments.insert(midnight)
        }
        return moments.filter { $0 > now }.sorted()
    }
}

/// yyyy-MM-dd for a local day. The same format as ArrdeckData's CalendarDay,
/// repeated here because the widget extension does not link that package.
public enum GlanceDay {
    public static func iso(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
