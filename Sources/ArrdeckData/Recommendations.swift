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

extension LiveAPI: RecommendationsAPI, QueueGrabAPI {
    public func recommendations() async throws -> [SearchResult] {
        try await call {
            switch try await client.recommendations_api_v1_discover_recommendations_get() {
            case let .ok(ok): try ok.body.json
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func dismissRecommendation(_ tmdbID: Int) async throws {
        try await call {
            switch try await client.dismiss_recommendation_api_v1_discover_recommendations__tmdb_id__dismiss_post(
                path: .init(tmdb_id: tmdbID)
            ) {
            case .noContent: ()
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func grabNow(app: ArrApp, id: Int) async throws {
        try await call {
            switch try await client.grab_now_api_v1_queue__app___item_id__grab_post(path: .init(app: app.rawValue, item_id: id)) {
            case .noContent: ()
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }
}
