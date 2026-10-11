import Foundation

/// Where a tap on a widget or the Live Activity lands: `arrdeck://open/activity`.
/// The app hands it to its LaunchRouter, the same path a quick action takes.
/// A host of its own keeps it apart from the sign-in callback
/// (`arrdeck://paired?code=…`) that shares the scheme.
public enum GlanceLink: String, CaseIterable, Sendable {
    case activity, calendar, settings

    public static let scheme = "arrdeck"
    static let host = "open"

    public var url: URL {
        var parts = URLComponents()
        parts.scheme = Self.scheme
        parts.host = Self.host
        parts.path = "/" + rawValue
        return parts.url!
    }

    public init?(url: URL) {
        guard url.scheme == Self.scheme, url.host() == Self.host else { return nil }
        self.init(rawValue: url.lastPathComponent)
    }
}
