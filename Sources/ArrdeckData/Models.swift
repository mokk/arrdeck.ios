import ArrdeckAPI

// Readable names over the generated schema types. The generated code is the
// contract; these keep call sites free of `Components.Schemas.*Out`.
public typealias ServiceInfo = Components.Schemas.ServiceInfoOut
public typealias PlaySession = Components.Schemas.PlaySessionOut
public typealias HealthWarning = Components.Schemas.HealthWarningOut
public typealias MediaRequest = Components.Schemas.MediaRequestOut
public typealias RecentItem = Components.Schemas.RecentItemOut
public typealias TorrentSummary = Components.Schemas.TorrentSummaryOut
public typealias Torrent = Components.Schemas.TorrentOut
public typealias QueueItem = Components.Schemas.QueueItemOut
public typealias CalendarItem = Components.Schemas.CalendarItemOut
public typealias DiskSpace = Components.Schemas.DiskSpaceOut
public typealias VpnStatus = Components.Schemas.VpnStatusOut
public typealias Subtitles = Components.Schemas.SubtitlesOut
public typealias SubtitleItem = Components.Schemas.SubtitleItemOut
public typealias HistoryItem = Components.Schemas.HistoryItemOut
public typealias HistoryEvent = Components.Schemas.HistoryEventOut
public typealias IndexerStats = Components.Schemas.IndexerStatsOut
public typealias StatsSample = Components.Schemas.StatsSampleOut

extension Components.Schemas.ServiceBlock_list_PlaySessionOut__: ServiceBlockShape {}
extension Components.Schemas.ServiceBlock_list_HealthWarningOut__: ServiceBlockShape {}
extension Components.Schemas.ServiceBlock_list_MediaRequestOut__: ServiceBlockShape {}
extension Components.Schemas.ServiceBlock_TorrentSummaryOut_: ServiceBlockShape {}
extension Components.Schemas.ServiceBlock_list_QueueItemOut__: ServiceBlockShape {}
extension Components.Schemas.ServiceBlock_list_CalendarItemOut__: ServiceBlockShape {}
extension Components.Schemas.ServiceBlock_list_DiskSpaceOut__: ServiceBlockShape {}
extension Components.Schemas.ServiceBlock_VpnStatusOut_: ServiceBlockShape {}
extension Components.Schemas.ServiceBlock_SubtitlesOut_: ServiceBlockShape {}
extension Components.Schemas.ServiceBlock_list_HistoryItemOut__: ServiceBlockShape {}
extension Components.Schemas.ServiceBlock_IndexerStatsOut_: ServiceBlockShape {}

/// The two arrs every paired endpoint answers for.
public enum ArrApp: String, CaseIterable, Sendable, Hashable {
    case radarr, sonarr, readarr
}

public enum TorrentClient: String, CaseIterable, Sendable, Hashable {
    case qbittorrent, transmission
}

public enum Services {
    /// Display names, as the PWA spells them.
    public static func label(_ service: String) -> String {
        switch service {
        case "radarr": "Radarr"
        case "sonarr": "Sonarr"
        case "readarr": "Readarr"
        case "prowlarr": "Prowlarr"
        case "qbittorrent": "qBittorrent"
        case "transmission": "Transmission"
        case "overseerr": "Overseerr"
        case "gluetun": "gluetun"
        case "bazarr": "Bazarr"
        case "plex": "Plex"
        case "prometheus": "Prometheus"
        default: service
        }
    }
}
