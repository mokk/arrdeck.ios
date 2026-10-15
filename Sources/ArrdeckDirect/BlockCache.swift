import ArrdeckData
import Foundation

/// Last good answers, kept past their freshness on purpose: a service that
/// goes down still shows what it last said, under an age note, the way the
/// server's cache let it. Bounded, least recently used first out — keys like
/// a calendar's date range gain an entry for every week anyone browses.
final class BlockCache: Sendable {
    static let maxEntries = 512
    private let entries = Locked<[String: Entry]>([:])

    struct Entry: @unchecked Sendable {
        var stored: Date
        var used: Date
        // Sendable values only go in (see `set`); typed back out by the caller
        var value: Any
    }

    func fresh<T: Sendable>(_ key: String, ttl: TimeInterval, now: Date = .now) -> T? {
        entries.withLock { all in
            guard var entry = all[key], now.timeIntervalSince(entry.stored) <= ttl else { return nil }
            entry.used = now
            all[key] = entry
            return entry.value as? T
        }
    }

    func stale<T: Sendable>(_ key: String, now: Date = .now) -> (age: TimeInterval, value: T)? {
        entries.withLock { all in
            guard var entry = all[key], let value = entry.value as? T else { return nil }
            entry.used = now
            all[key] = entry
            return (now.timeIntervalSince(entry.stored), value)
        }
    }

    func set<T: Sendable>(_ key: String, _ value: T, now: Date = .now) {
        entries.withLock { all in
            all[key] = Entry(stored: now, used: now, value: value)
            if all.count > Self.maxEntries, let oldest = all.min(by: { $0.value.used < $1.value.used })?.key {
                all[oldest] = nil
            }
        }
    }

    /// After a change that makes an entry wrong: the next read goes upstream,
    /// and a failing one has no stale value to fall back on.
    func remove(_ keys: [String]) {
        entries.withLock { all in
            for key in keys { all[key] = nil }
        }
    }

    func clear() {
        entries.withLock { $0.removeAll() }
    }
}

extension DirectBackend {
    /// One service's slice of an aggregate. Never throws: a dead service
    /// becomes an offline block, with its last good value when there is one.
    func guarded<T: Sendable & Equatable>(_ key: String?, _ fetch: () async throws -> T) async -> Block<T> {
        do {
            let value = try await fetch()
            if let key { cache.set(key, value) }
            return .healthy(value)
        } catch {
            if let key, let (age, value): (TimeInterval, T) = cache.stale(key) {
                return .stale(value, age: age)
            }
            return .offline(Self.reason(error))
        }
    }

    /// A fetch reused for `ttl` seconds — the lists every screen reads.
    func cached<T: Sendable>(_ key: String, ttl: TimeInterval, _ fetch: () async throws -> T) async throws -> T {
        if let hit: T = cache.fresh(key, ttl: ttl) { return hit }
        let value = try await fetch()
        cache.set(key, value)
        return value
    }

    /// What the server's `cache.set(key, None)` did after a write: the next
    /// read of these keys fetches afresh.
    func forget(_ keys: String...) {
        cache.remove(keys)
    }

    /// After a change to Lidarr's library: the Music tab, the import picker
    /// and the search badges read afresh (music.py's `forget_artists`).
    func forgetArtists() {
        forget(CatalogMusic.artistsKey, CatalogMusic.libraryKey)
    }

    /// Drops the cached lists a bulk change makes wrong, under the server's
    /// keys, so the next read goes to the arr. (Books and artists clearing the
    /// series map is the server's doing, kept as it was.)
    func forgetLibrary(_ app: LibraryApp, authors: Bool) {
        forget(app == .radarr ? "library_map:movie" : "library_map:series")
        if authors { forget("readarr:authors") }
        if app == .lidarr { forgetArtists() }
    }

    static func reason(_ error: any Error) -> String {
        switch error {
        case let error as ServiceUnavailable: error.message
        case let error as ServiceRefused: error.description
        case let error as APIError: error.description
        default: error.localizedDescription
        }
    }
}
