import ArrdeckAPI
import Foundation

public typealias Exclusion = Components.Schemas.ExclusionOut
public typealias ParseResult = Components.Schemas.ParseOut
public typealias SeasonGridRow = Components.Schemas.SeasonGridOut

/// Exclusions, the release name tester and the season grid.
public protocol ToolsAPI: Sendable {
    func exclusions() async throws -> [Exclusion]
    func removeExclusion(app: String, id: Int) async throws
    func parse(app: ArrApp, title: String) async throws -> ParseResult
    func seasonGrid() async throws -> [SeasonGridRow]
}

extension LiveAPI: ToolsAPI {
    public func exclusions() async throws -> [Exclusion] {
        try await call {
            switch try await client.exclusions_api_v1_exclusions_get() {
            case let .ok(ok): try ok.body.json
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func removeExclusion(app: String, id: Int) async throws {
        try await call {
            switch try await client.remove_exclusion_api_v1_exclusions__app___exclusion_id__delete(
                path: .init(app: app, exclusion_id: id)
            ) {
            case .noContent: ()
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func parse(app: ArrApp, title: String) async throws -> ParseResult {
        try await call {
            switch try await client.parse_api_v1_parse__app__get(path: .init(app: app.rawValue), query: .init(title: title)) {
            case let .ok(ok): try ok.body.json
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func seasonGrid() async throws -> [SeasonGridRow] {
        try await call {
            switch try await client.season_grid_api_v1_library_series_seasons_get() {
            case let .ok(ok): try ok.body.json
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }
}

extension ParseResult {
    /// S06E03, or S06 (full season); nil for a film.
    public var episodeCode: String? {
        guard let season else { return nil }
        let episodes = (episodes ?? []).map { String(format: "E%02d", $0) }.joined()
        return String(format: "S%02d", season) + episodes + (full_season == true ? " (\(String(localized: "full season")))" : "")
    }
}
