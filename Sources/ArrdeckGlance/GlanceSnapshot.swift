import Foundation

/// What the widgets show: a small copy of the dashboard the app writes each
/// time it refreshes, because the widget extension has no network client or
/// credentials of its own and must not get them.
///
/// Every section carries the moment it was fetched. The sections refresh at
/// different rates (torrents every few seconds, the calendar and disks every
/// five minutes), and a section the app has not heard about yet keeps the
/// previous copy rather than blanking it — so how old each one is differs,
/// and the widgets judge them separately.
public struct GlanceSnapshot: Codable, Sendable, Equatable {
    /// Bumped whenever a field changes meaning. A widget reading another
    /// version shows "Open arrdeck to load" rather than misread the file.
    public static let currentVersion = 1

    public var version: Int
    /// The saved server's name, so two servers' copies are never merged.
    public var server: String
    /// nil: no torrent client, or none has answered yet.
    public var downloads: Downloads?
    public var today: Today?
    public var disk: Disk?
    /// What arrived lately. Optional, so a file written before it existed
    /// still reads.
    public var activity: Activity?
    /// 1000 or 1024: Settings → Display → Sizes, so a widget's "1.2 TB" is the app's.
    public var byteBase: Int

    public init(server: String, downloads: Downloads? = nil, today: Today? = nil, disk: Disk? = nil,
                activity: Activity? = nil, byteBase: Int = 1024) {
        self.version = Self.currentVersion
        self.server = server
        self.downloads = downloads
        self.today = today
        self.disk = disk
        self.activity = activity
        self.byteBase = byteBase
    }

    /// The newest of the sections' times; nil when there is nothing at all.
    public var takenAt: Date? {
        [downloads?.at, today?.at, disk?.at, activity?.at].compactMap { $0 }.max()
    }

    public var isEmpty: Bool { downloads == nil && today == nil && disk == nil && activity == nil }

    /// This copy over an older one: a section this copy does not have keeps
    /// the older one's, with its older time. Another server's copy is not
    /// worth keeping any part of.
    public func merging(_ older: GlanceSnapshot?) -> GlanceSnapshot {
        guard let older, older.server == server, older.version == version else { return self }
        var merged = self
        merged.downloads = downloads ?? older.downloads
        merged.today = today ?? older.today
        merged.disk = disk ?? older.disk
        merged.activity = activity ?? older.activity
        return merged
    }
}

extension GlanceSnapshot {
    /// What the torrent clients are fetching. Only torrents actually
    /// downloading count — seeding is the steady state of most of them.
    public struct Downloads: Codable, Sendable, Equatable {
        public var at: Date
        /// The fastest first, at most `GlanceSnapshot.Downloads.shown`.
        public var top: [Item]
        public var count: Int
        /// Bytes a second across every client.
        public var speed: Int
        /// All of them together, weighted by size; nil when sizes are unknown.
        public var progress: Double?
        /// Seconds until the last one finishes; nil when no client can say.
        public var eta: Int?

        public static let shown = 3

        public init(at: Date, top: [Item], count: Int, speed: Int, progress: Double?, eta: Int?) {
            self.at = at
            self.top = top
            self.count = count
            self.speed = speed
            self.progress = progress
            self.eta = eta
        }

        public struct Item: Codable, Sendable, Equatable, Hashable {
            public var name: String
            public var progress: Double
            public var speed: Int
            public var eta: Int?

            public init(name: String, progress: Double, speed: Int, eta: Int?) {
                self.name = name
                self.progress = progress
                self.speed = speed
                self.eta = eta
            }
        }
    }

    /// What comes out on one local calendar day.
    public struct Today: Codable, Sendable, Equatable {
        public var at: Date
        /// yyyy-MM-dd in the phone's time zone when it was written. A copy
        /// from yesterday is not "today", however recently it was written.
        public var day: String
        /// The first few, earliest first.
        public var entries: [Entry]
        /// Every entry of the day, including those not in `entries`.
        public var count: Int

        public static let shown = 4

        public init(at: Date, day: String, entries: [Entry], count: Int) {
            self.at = at
            self.day = day
            self.entries = entries
            self.count = count
        }

        public struct Entry: Codable, Sendable, Equatable, Hashable {
            public enum Kind: String, Codable, Sendable { case episode, movie, book, album }
            public var kind: Kind
            public var title: String
            /// S01E05, or S01E01–E08 when a season drops at once.
            public var code: String?
            /// The moment an episode airs; nil for a film's, a book's or an album's release day.
            public var time: Date?
            public var downloaded: Bool

            public init(kind: Kind, title: String, code: String? = nil, time: Date? = nil, downloaded: Bool = false) {
                self.kind = kind
                self.title = title
                self.code = code
                self.time = time
                self.downloaded = downloaded
            }
        }
    }

    /// What the arrs did lately — arrived, failed, grabbed — newest first,
    /// for the Activity widget. History stays true as it ages, only
    /// incomplete: what came after the last poll is missing.
    public struct Activity: Codable, Sendable, Equatable {
        public var at: Date
        public var entries: [Entry]

        /// Enough for the large widget; the smaller ones show the first few.
        public static let shown = 8

        public init(at: Date, entries: [Entry]) {
            self.at = at
            self.entries = entries
        }

        public struct Entry: Codable, Sendable, Equatable, Hashable {
            public enum Kind: String, Codable, Sendable { case episode, movie, book, album }
            public enum Event: String, Codable, Sendable {
                /// Imported into the library: it is there to watch or read.
                case arrived
                case failed
                /// Sent to a download client, not imported yet.
                case grabbed
            }

            public var kind: Kind
            public var event: Event
            /// The library's title when the app knows it, the release name
            /// cleaned up otherwise.
            public var title: String
            /// S02E08, or S02E02–E08 for a run of one season's episodes.
            public var code: String?
            /// Episodes folded into this entry; 1 for anything else.
            public var count: Int
            /// The newest of them.
            public var date: Date
            /// Names the title's poster in the shared container (movie-207);
            /// nil when the title is not in the library the app has loaded.
            public var key: String?
            /// The poster file for `key` is there to show.
            public var hasPoster: Bool

            public init(kind: Kind, event: Event, title: String, code: String? = nil, count: Int = 1, date: Date,
                        key: String? = nil, hasPoster: Bool = false) {
                self.kind = kind
                self.event = event
                self.title = title
                self.code = code
                self.count = count
                self.date = date
                self.key = key
                self.hasPoster = hasPoster
            }
        }
    }

    /// The fullest place things are stored.
    public struct Disk: Codable, Sendable, Equatable {
        public var at: Date
        public var free: Int
        /// nil: the arrs' root folders report free space only, so a gauge
        /// would have nothing honest to fill against.
        public var total: Int?
        public var label: String?

        public init(at: Date, free: Int, total: Int?, label: String?) {
            self.at = at
            self.free = free
            self.total = total
            self.label = label
        }

        /// How full, 0…1, only when there is a total.
        public var used: Double? {
            guard let total, total > 0 else { return nil }
            return min(max(Double(total - free) / Double(total), 0), 1)
        }
    }
}
