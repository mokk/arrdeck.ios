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
