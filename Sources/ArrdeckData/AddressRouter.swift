import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Where a profile's requests go right now: its primary address, or its home
/// address while that answers. Shared by reference between the API client,
/// which reads it per request, and the session controller, which moves it
/// after probing — so a switch takes effect for every screen at once without
/// rebuilding the client.
public final class AddressRouter: @unchecked Sendable {
    private let lock = NSLock()
    private let primary: URL
    private var home: URL?
    private var onHome = false
    private var onFallback: (@Sendable () -> Void)?

    public init(primary: URL, home: URL? = nil) {
        self.primary = primary
        self.home = home
    }

    /// The address the next request goes to.
    public var current: URL {
        lock.withLock { onHome ? home ?? primary : primary }
    }

    public var isHome: Bool {
        lock.withLock { onHome && home != nil }
    }

    /// Moves to the home address (when there is one) or back to the primary.
    public func use(home useHome: Bool) {
        lock.withLock { onHome = useHome && home != nil }
    }

    /// A new or removed home address. Removing it moves to the primary.
    public func setHome(_ url: URL?) {
        lock.withLock {
            home = url
            if url == nil { onHome = false }
        }
    }

    /// Told when a request fell back, so the screen showing "At home" can stop.
    public func setOnFallback(_ handler: (@Sendable () -> Void)?) {
        lock.withLock { onFallback = handler }
    }

    /// A request to `url` never reached the backend. Returns the address to
    /// retry it on, or nil when there is none: a request that failed on the
    /// primary has nowhere else to go, which is what keeps this from looping.
    ///
    /// Retries go to the primary even when the router already moved there
    /// (a probe settled while the request was in flight); the move and its
    /// notification happen once, for the first request that notices.
    func fallBack(from url: URL) -> URL? {
        let (retry, notify): (URL?, (@Sendable () -> Void)?) = lock.withLock {
            guard url != primary else { return (nil, nil) }
            let wasHome = onHome
            onHome = false
            return (primary, wasHome ? onFallback : nil)
        }
        notify?()
        return retry
    }
}

/// The generated client's transport, sending each request to the router's
/// current address instead of the fixed server URL the client was built with,
/// and retrying once on the primary when the home address cannot be reached.
struct RoutingTransport: ClientTransport {
    let base: any ClientTransport
    let router: AddressRouter

    func send(
        _ request: HTTPRequest, body: HTTPBody?, baseURL _: URL, operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let target = router.current
        do {
            return try await base.send(request, body: body, baseURL: target, operationID: operationID)
        } catch {
            guard let reach = Self.unreached(error) else { throw error }
            // Leave the home address even when this request cannot be retried:
            // the next one should not try it again.
            guard let retry = router.fallBack(from: target),
                  Self.canRetry(request.method, body: body, reach: reach)
            else { throw error }
            return try await base.send(request, body: body, baseURL: retry, operationID: operationID)
        }
    }

    /// How sure a transport error is that the backend never saw the request.
    enum Reach {
        /// No connection was ever made: safe to resend anything.
        case never
        /// The connection was made or the answer was lost: the request may
        /// have arrived.
        case maybe
    }

    static func unreached(_ error: any Error) -> Reach? {
        guard let error = error as? URLError else { return nil }
        switch error.code {
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet:
            return .never
        case .timedOut, .networkConnectionLost:
            return .maybe
        default:
            return nil
        }
    }

    /// A POST that may have arrived is not sent twice — adding a torrent or a
    /// title twice is worse than one error. A streamed body cannot be sent
    /// twice at all.
    static func canRetry(_ method: HTTPRequest.Method, body: HTTPBody?, reach: Reach) -> Bool {
        if let body, body.iterationBehavior != .multiple { return false }
        switch method {
        case .get, .head, .options, .put, .delete: return true
        default: return reach == .never
        }
    }
}
