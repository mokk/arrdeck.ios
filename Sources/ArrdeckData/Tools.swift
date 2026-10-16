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

extension ParseResult {
    /// S06E03, or S06 (full season); nil for a film.
    public var episodeCode: String? {
        guard let season else { return nil }
        let episodes = (episodes ?? []).map { String(format: "E%02d", $0) }.joined()
        return String(format: "S%02d", season) + episodes + (full_season == true ? " (\(String(localized: "full season")))" : "")
    }
}
