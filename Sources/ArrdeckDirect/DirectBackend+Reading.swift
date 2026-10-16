import ArrdeckData
import Foundation

/// Where a profile's reading statuses are kept. Readarr has no such notion;
/// the server kept them in its settings store, the device keeps them itself,
/// so they stay on this device.
public protocol ReadingStore: Sendable {
    func load() -> [Int: Reading]
    func save(_ statuses: [Int: Reading])
}

public final class InMemoryReadingStore: ReadingStore {
    private let statuses: Locked<[Int: Reading]>

    public init(_ statuses: [Int: Reading] = [:]) {
        self.statuses = Locked(statuses)
    }

    public func load() -> [Int: Reading] { statuses.withLock { $0 } }
    public func save(_ statuses: [Int: Reading]) { self.statuses.withLock { $0 = statuses } }
}

/// One JSON value per profile in the app's defaults: a few bytes a book, and
/// nothing in it is a secret.
public struct DefaultsReadingStore: ReadingStore {
    let key: String

    public init(profileID: UUID) {
        key = Self.key(profileID)
    }

    static func key(_ profileID: UUID) -> String { "reading.\(profileID.uuidString)" }

    public func load() -> [Int: Reading] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let raw = try? JSONDecoder().decode([String: Reading].self, from: data)
        else { return [:] }
        return raw.reduce(into: [:]) { out, pair in if let id = Int(pair.key) { out[id] = pair.value } }
    }

    public func save(_ statuses: [Int: Reading]) {
        let raw = Dictionary(uniqueKeysWithValues: statuses.map { (String($0.key), $0.value) })
        guard let data = try? JSONEncoder().encode(raw) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// When the profile is removed.
    public static func delete(profileID: UUID) {
        UserDefaults.standard.removeObject(forKey: key(profileID))
    }
}

extension DirectBackend: ReadingAPI {
    public func reading() async throws -> [Int: Reading] {
        readingStore.load()
    }

    public func setReading(_ bookID: Int, _ status: ReadingStatus?) async throws -> [Int: Reading] {
        let statuses = Self.apply(readingStore.load(), bookID, status, now: Int(Date.now.timeIntervalSince1970))
        readingStore.save(statuses)
        return statuses
    }

    /// The map after one change, as the server's reading.py has it: marking
    /// read stamps when, and moving a finished book back to reading or to-read
    /// forgets that date.
    static func apply(_ statuses: [Int: Reading], _ bookID: Int, _ status: ReadingStatus?, now: Int) -> [Int: Reading] {
        var out = statuses
        guard let status, let wire = Reading.statusPayload(rawValue: status.rawValue) else {
            out[bookID] = nil
            return out
        }
        let previous = out[bookID]
        let finished = previous?.readingStatus == .read ? previous?.finished_at : nil
        out[bookID] = Reading(finished_at: status == .read ? finished ?? now : nil, status: wire, updated_at: now)
        return out
    }
}
