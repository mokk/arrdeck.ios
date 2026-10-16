import Foundation

/// Everything a profile's screens ask of whatever answers them, without a
/// cast: the direct backend, which talks to the services themselves, and the
/// tests' stand-ins. Capabilities the screens reach with `api as? any …API`
/// stay out of this, so a stand-in that has not got one simply leaves its
/// screen out.
public protocol Backend:
    DashboardAPI, ActivityAPI, ManageAPI, LibraryAPI, ExtrasAPI, DiscoverAPI, WantedAPI,
    BookShelfAPI, MusicLibraryAPI, IndexerAddAPI, HistoryAPI, DownloadsAPI, CalendarAPI {}
