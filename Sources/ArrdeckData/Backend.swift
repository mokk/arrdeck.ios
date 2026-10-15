import Foundation

/// Everything a server's screens ask of whatever answers them, without a cast.
/// Two things do: `LiveAPI`, an arrdeck backend over HTTP, and the direct
/// backend, which talks to the services themselves. Capabilities the screens
/// reach with `api as? any …API` stay out of this, so a backend that has not
/// got one simply leaves its screen out.
public protocol Backend:
    DashboardAPI, ActivityAPI, PrefsAPI, ManageAPI, LibraryAPI, ExtrasAPI, DiscoverAPI, WantedAPI,
    BookShelfAPI, MusicLibraryAPI, IndexerAddAPI, HistoryAPI, DownloadsAPI, CalendarAPI {}

extension LiveAPI: Backend {}

extension APIError {
    /// What a direct connection answers for something only the arrdeck
    /// server can do, or that has not been brought into the app yet.
    public static var needsServer: APIError {
        .refused(String(localized: "This needs the arrdeck server."))
    }
}
