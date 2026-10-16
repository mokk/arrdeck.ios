import ArrdeckAPI
import Foundation

public typealias Reading = Components.Schemas.ReadingOut

/// To read, reading, read. Readarr has no such notion, so the app keeps it,
/// on this device.
public enum ReadingStatus: String, CaseIterable, Sendable, Hashable {
    case toRead = "to_read", reading, read

    public var label: String {
        switch self {
        case .toRead: String(localized: "To read")
        case .reading: String(localized: "Reading")
        case .read: String(localized: "Read")
        }
    }
}

public protocol ReadingAPI: Sendable {
    func reading() async throws -> [Int: Reading]
    func setReading(_ bookID: Int, _ status: ReadingStatus?) async throws -> [Int: Reading]
}

extension Reading {
    public var readingStatus: ReadingStatus? { ReadingStatus(rawValue: status.rawValue) }
}
