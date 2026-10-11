import Foundation

/// Sizes, speeds and times as the widgets write them. The bytes match
/// ArrdeckData's Format.bytes (repeated: the extension does not link it),
/// with the base the app's Sizes setting chose carried in the snapshot.
public enum GlanceFormat {
    public static func bytes(_ count: Int, base: Int, locale: Locale = .current) -> String {
        guard count > 0 else { return "0 B" }
        let base = Double(base == 1000 ? 1000 : 1024)
        let units = ["B", "KB", "MB", "GB", "TB"]
        let exponent = min(Int(log(Double(count)) / log(base)), units.count - 1)
        let value = Double(count) / pow(base, Double(exponent))
        let digits = exponent == 0 ? 0 : 1
        return "\(value.formatted(.number.precision(.fractionLength(digits)).locale(locale))) \(units[exponent])"
    }

    public static func speed(_ bytesPerSecond: Int, base: Int, locale: Locale = .current) -> String {
        "\(bytes(bytesPerSecond, base: base, locale: locale))/s"
    }

    /// 0.456 → "45%": rounded down, so nothing reads 100% before it is done.
    public static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded(.down)))%"
    }

    /// When something estimated `eta` seconds at `at` should be done. A
    /// moment rather than "in 20 min", so it stays true after the app stops
    /// updating — a countdown frozen on a widget would not.
    public static func finish(_ eta: Int, from at: Date) -> Date {
        at.addingTimeInterval(TimeInterval(eta))
    }
}
