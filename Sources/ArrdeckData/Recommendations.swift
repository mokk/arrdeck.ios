import ArrdeckAPI
import Foundation

/// Radarr's own suggestions from the library, and "not interested".
public protocol RecommendationsAPI: Sendable {
    func recommendations() async throws -> [SearchResult]
    func dismissRecommendation(_ tmdbID: Int) async throws
}

/// Sending a release a delay profile is holding to the client now.
public protocol QueueGrabAPI: Sendable {
    func grabNow(app: ArrApp, id: Int) async throws
}
