import Foundation
@testable import ArrdeckDirect

/// Answers requests from a script, and records them. Unscripted requests fail
/// the way an unreachable host does.
final class StubTransport: ServiceTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> ServiceResponse
    private let lock = NSLock()
    private var handlers: [(String, Handler)] = []
    private(set) var sent: [URLRequest] = []

    /// `match` is "METHOD path-suffix", e.g. "GET /api/v3/movie".
    func on(_ match: String, _ handler: @escaping Handler) {
        lock.withLock { handlers.append((match, handler)) }
    }

    func on(_ match: String, status: Int = 200, json: String, headers: [String: String] = [:]) {
        on(match) { _ in ServiceResponse(status: status, headers: headers, data: Data(json.utf8)) }
    }

    func send(_ request: URLRequest) async throws -> ServiceResponse {
        let handler: Handler? = lock.withLock {
            sent.append(request)
            let method = request.httpMethod ?? "GET"
            let path = request.url?.path() ?? ""
            return handlers.last { match, _ in
                let parts = match.split(separator: " ", maxSplits: 1).map(String.init)
                return parts[0] == method && path.hasSuffix(parts[1])
            }?.1
        }
        guard let handler else { throw URLError(.cannotConnectToHost) }
        return try handler(request)
    }

    var requests: [URLRequest] { lock.withLock { sent } }
}

func backend(
    _ connections: [String: ServiceConnection], transport: StubTransport = StubTransport()
) -> (DirectBackend, StubTransport) {
    let registry = Registry(store: InMemoryConnectionStore(connections), transport: transport)
    return (DirectBackend(registry: registry), transport)
}

extension ServiceConnection {
    static func arr(_ url: String = "http://10.0.0.5:8989", key: String = "secret") -> ServiceConnection {
        ServiceConnection(url: url, apiKey: key)
    }
}
