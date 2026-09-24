import ArrdeckAPI
import Foundation

/// Trakt's public lists, as search results the add sheet takes as they are.
public protocol TraktAPI: Sendable {
    func traktList(movies: Bool, list: TraktList) async throws -> [SearchResult]
}

public enum TraktList: String, CaseIterable, Sendable {
    case trending, anticipated, popular

    public var label: String {
        switch self {
        case .trending: String(localized: "Trending")
        case .anticipated: String(localized: "Anticipated")
        case .popular: String(localized: "Popular")
        }
    }
}

extension LiveAPI: TraktAPI {
    public func traktList(movies: Bool, list: TraktList) async throws -> [SearchResult] {
        try await call {
            switch try await client.trakt_list_api_v1_discover_trakt_get(
                query: .init(kind: movies ? .movie : .series, which: .init(rawValue: list.rawValue) ?? .trending)
            ) {
            case let .ok(ok): try ok.body.json
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }
}
