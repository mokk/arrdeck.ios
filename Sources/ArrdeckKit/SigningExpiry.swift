import Foundation

/// When this build stops launching. A free (Personal Team) signature lasts
/// seven days from when Xcode made the profile — not from the install, so a
/// reinstall inside the week does not move it — and then iOS refuses to open
/// the app without a word. Read from the profile the build carries, so the
/// app can say so first.
public enum SigningExpiry {
    /// How far ahead the in-app warning starts.
    public static let warningWindow: TimeInterval = 2 * 24 * 3600

    /// The running build's expiry; nil without an embedded profile (the
    /// simulator, App Store and TestFlight builds), where none of this applies.
    public static func current(bundle: Bundle = .main) -> Date? {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return date(fromProfile: data)
    }

    /// A provisioning profile is a CMS envelope around a plain XML plist, so
    /// the plist can be cut out by its markers without unwrapping the
    /// signature — nothing here relies on it being genuine.
    public static func date(fromProfile data: Data) -> Date? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data[start.lowerBound..<end.upperBound], format: nil
              ) as? [String: Any]
        else { return nil }
        return plist["ExpirationDate"] as? Date
    }

    /// Whether to warn now: inside the window, and not already past (an
    /// expired build is not running to show anything).
    public static func isClose(_ expiry: Date, now: Date = .now) -> Bool {
        let left = expiry.timeIntervalSince(now)
        return left > 0 && left <= warningWindow
    }
}
