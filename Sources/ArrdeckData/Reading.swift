import ArrdeckAPI
import Foundation

public typealias Reading = Components.Schemas.ReadingOut
public typealias OpdsSettings = Components.Schemas.OpdsSettingsOut

/// To read, reading, read — kept in arrdeck, so the PWA and the app agree.
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

/// The OPDS catalogue's switch and secret.
public protocol OpdsAPI: Sendable {
    func opdsSettings() async throws -> OpdsSettings
    func setOpds(enabled: Bool) async throws -> OpdsSettings
}

extension LiveAPI: ReadingAPI, OpdsAPI {
    static func byBook(_ raw: [String: Reading]) -> [Int: Reading] {
        raw.reduce(into: [:]) { out, pair in if let id = Int(pair.key) { out[id] = pair.value } }
    }

    public func reading() async throws -> [Int: Reading] {
        try await call {
            switch try await client.reading_api_v1_library_books_reading_get() {
            case let .ok(ok): Self.byBook(try ok.body.json.additionalProperties)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func setReading(_ bookID: Int, _ status: ReadingStatus?) async throws -> [Int: Reading] {
        let body = Components.Schemas.ReadingIn(status: status.flatMap { .init(rawValue: $0.rawValue) })
        return try await call {
            switch try await client.set_reading_api_v1_library_books__book_id__reading_put(
                path: .init(book_id: bookID), body: .json(body)
            ) {
            case let .ok(ok): Self.byBook(try ok.body.json.additionalProperties)
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func opdsSettings() async throws -> OpdsSettings {
        try await call {
            switch try await client.opds_settings_api_v1_opds_settings_get() {
            case let .ok(ok): try ok.body.json
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func setOpds(enabled: Bool) async throws -> OpdsSettings {
        try await call {
            if enabled {
                switch try await client.opds_new_token_api_v1_opds_settings_token_post() {
                case let .ok(ok): return try ok.body.json
                case let .undocumented(code, _): throw APIError.status(code)
                }
            } else {
                switch try await client.opds_disable_api_v1_opds_settings_token_delete() {
                case let .ok(ok): return try ok.body.json
                case let .undocumented(code, _): throw APIError.status(code)
                }
            }
        }
    }
}

extension Reading {
    public var readingStatus: ReadingStatus? { ReadingStatus(rawValue: status.rawValue) }
}

extension OpdsSettings {
    /// The catalogue address on the server this app talks to.
    public func url(on base: URL) -> URL? {
        guard let token, !token.isEmpty else { return nil }
        return base.appending(path: "opds").appending(path: token)
    }
}
