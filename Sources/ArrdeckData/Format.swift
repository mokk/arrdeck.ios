import Foundation

/// Display formatting shared by the cards. Locale and clock are parameters so
/// tests pin exact strings; the defaults are the device's.
public enum Format {
    /// "0 B", "1.5 GB", "2.4 TB" — one decimal above bytes, as the PWA prints
    /// them; steps of 1024 or 1000 per Settings → Display.
    public static func bytes(_ count: Int?, locale: Locale = .current, style: SizeStyle? = nil) -> String {
        guard let count, count > 0 else { return "0 B" }
        let base: Double = (style ?? UserDefaults.standard.pref(DisplayKeys.sizes, default: SizeStyle.binary)) == .decimal ? 1000 : 1024
        let units = ["B", "KB", "MB", "GB", "TB"]
        let exponent = min(Int(log(Double(count)) / log(base)), units.count - 1)
        let value = Double(count) / pow(base, Double(exponent))
        let digits = exponent == 0 ? 0 : 1
        let number = value.formatted(.number.precision(.fractionLength(digits)).locale(locale))
        return "\(number) \(units[exponent])"
    }

    /// A moment as "3 days ago" or as a date, per Settings → Display; the year
    /// shows when it is not this one.
    public static func when(_ date: Date, style: DateStyle? = nil, now: Date = .now, locale: Locale = .current) -> String {
        switch style ?? UserDefaults.standard.pref(DisplayKeys.dates, default: DateStyle.relative) {
        case .relative:
            return date.formatted(.relative(presentation: .named).locale(locale))
        case .absolute:
            let sameYear = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: now)
            let format = Date.FormatStyle(locale: locale).month(.abbreviated).day()
            return date.formatted(sameYear ? format : format.year())
        }
    }

    public static func speed(_ bytesPerSecond: Int, locale: Locale = .current) -> String {
        "\(bytes(bytesPerSecond, locale: locale))/s"
    }

    /// The arrs send RFC 3339 timestamps, with or without fractional seconds;
    /// a few fields are bare dates, which are local calendar days.
    public static func parseDate(_ string: String, timeZone: TimeZone = .current) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) {
            return date
        }
        if let date = try? Date.ISO8601FormatStyle().parse(string) {
            return date
        }
        return try? Date.ISO8601FormatStyle(timeZone: timeZone).year().month().day().parse(string)
    }

    /// "Today", "Tomorrow" or "Sep 29" — on a dashboard the first two are most
    /// of what anyone is looking for. Foundation supplies the words, so Danish
    /// gets "I dag" without a string of our own.
    public static func day(
        _ iso: String?, now: Date = .now, calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        guard let iso, let date = parseDate(iso, timeZone: calendar.timeZone) else { return "—" }
        if let named = namedDay(date, now: now, calendar: calendar, locale: locale) { return named }
        return date.formatted(style(locale, calendar).month(.abbreviated).day())
    }

    /// Like `day` with the time appended, keeping the comma so a named day and
    /// a dated one line up: "Today, 13:38" against "Sep 18, 17:31".
    public static func dayTime(
        _ iso: String, now: Date = .now, calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        guard let date = parseDate(iso, timeZone: calendar.timeZone) else { return "—" }
        let day = namedDay(date, now: now, calendar: calendar, locale: locale)
            ?? date.formatted(style(locale, calendar).month(.abbreviated).day())
        return "\(day), \(date.formatted(style(locale, calendar).hour().minute()))"
    }

    /// Whole days between today and `date`, by calendar day boundaries rather
    /// than 24-hour spans, so a DST changeover still counts as one day.
    static func namedDay(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String? {
        let offset = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)
        ).day ?? .max
        guard offset == 0 || offset == 1 else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.dateTimeStyle = .named
        let named = formatter.localizedString(from: DateComponents(day: offset))
        // It comes back lowercase; these sit alone in a cell, so capitalise.
        return named.prefix(1).uppercased(with: locale) + named.dropFirst()
    }

    private static func style(_ locale: Locale, _ calendar: Calendar) -> Date.FormatStyle {
        Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
    }
}
