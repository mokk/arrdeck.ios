import Foundation

/// A service could not be asked, or would not answer: down, refusing the key,
/// or not set up. What a card shows as its offline reason.
public struct ServiceUnavailable: Error, Equatable, Sendable, CustomStringConvertible {
    public let service: String
    public let message: String
    /// The request demonstrably never landed (or met a 5xx), so a GET may go
    /// once more.
    var transient = false

    public init(_ service: String, _ message: String = "unreachable") {
        self.service = service
        self.message = message
    }

    public var description: String { "\(service): \(message)" }

    static func notConfigured(_ service: String) -> ServiceUnavailable {
        ServiceUnavailable(service, "not configured")
    }
}

/// The service answered, but not with what was asked for: a 4xx the caller
/// may want to word, with the service's own message when it sent one.
public struct ServiceRefused: Error, Equatable, Sendable, CustomStringConvertible {
    public let service: String
    public let status: Int
    public let message: String

    public var description: String { message.isEmpty ? "\(service): HTTP \(status)" : message }
}

public struct ServiceResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let data: Data

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public func json() throws -> JSON {
        data.isEmpty ? .null : try JSON(data: data)
    }

    public var text: String { String(decoding: data, as: UTF8.self) }
}

/// The one way requests leave the app in direct mode. A protocol so tests can
/// answer them; `URLSessionServiceTransport` is the real one.
public protocol ServiceTransport: Sendable {
    func send(_ request: URLRequest) async throws -> ServiceResponse
}

public struct URLSessionServiceTransport: ServiceTransport {
    let session: URLSession

    /// Cookies stay per transport (qBittorrent's session lives in one) and
    /// off the shared store, which holds the arrdeck server's.
    public init(timeout: TimeInterval = 15) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        session = URLSession(configuration: config)
    }

    public func send(_ request: URLRequest) async throws -> ServiceResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        return ServiceResponse(status: http.statusCode, headers: headers, data: data)
    }
}

/// How often each service needed its one retry lately — the Connections
/// screen's "flaky" amber dot.
final class RetryLog: Sendable {
    /// Long enough that a service blipping a few times an hour still shows,
    /// short enough that yesterday's reboot does not brand it flaky forever.
    static let window: TimeInterval = 900
    private let stamps = Locked<[String: [Date]]>([:])

    func record(_ service: String, now: Date = .now) {
        stamps.withLock { $0[service, default: []].append(now) }
    }

    func count(_ service: String, now: Date = .now) -> Int {
        stamps.withLock { all in
            let recent = (all[service] ?? []).filter { now.timeIntervalSince($0) <= Self.window }
            all[service] = recent
            return recent.count
        }
    }
}

/// Sends one service's requests, with the backend's rules: one retry, and
/// only for a GET that never landed or met a 5xx. A re-sent grab, delete or
/// blocklist write is worse than an error — the arr would end up with two of
/// something and no way back.
struct ServiceHTTP: Sendable {
    let service: String
    let transport: any ServiceTransport
    let retries: RetryLog
    static let backoff: Duration = .milliseconds(250)

    func send(_ request: URLRequest) async throws -> ServiceResponse {
        do {
            return try await attempt(request)
        } catch let error as ServiceUnavailable where error.transient && (request.httpMethod ?? "GET") == "GET" {
            retries.record(service)
            try? await Task.sleep(for: Self.backoff)
            return try await attempt(request)
        }
    }

    private func attempt(_ request: URLRequest) async throws -> ServiceResponse {
        let response: ServiceResponse
        do {
            response = try await transport.send(request)
        } catch let error as URLError {
            var failure = ServiceUnavailable(service, Self.describe(error))
            // a read timeout did land: the service is slow, and asking again
            // doubles the wait and the load
            failure.transient = error.code != .timedOut
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ServiceUnavailable(service, error.localizedDescription)
        }
        if response.status >= 500 {
            // the arrs answer 5xx while a task holds their database lock,
            // which clears in well under a second
            var failure = ServiceUnavailable(service, "upstream HTTP \(response.status)")
            failure.transient = true
            throw failure
        }
        return response
    }

    static func describe(_ error: URLError) -> String {
        switch error.code {
        case .timedOut: "timed out"
        case .cannotFindHost, .dnsLookupFailed: "address not found"
        case .cannotConnectToHost: "connection refused"
        case .notConnectedToInternet: "no network"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
            "TLS failed"
        case .appTransportSecurityRequiresSecureConnection: "plain HTTP is only allowed on the home network"
        default: error.localizedDescription
        }
    }
}

/// A request builder over one service's base address.
struct Endpoint: Sendable {
    let base: URL

    /// `base` may carry a path (a reverse proxy's /sonarr); `path` is appended
    /// to it rather than replacing it.
    init?(_ raw: String) {
        var trimmed = raw.trimmingCharacters(in: .whitespaces)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), url.scheme != nil, url.host() != nil else { return nil }
        base = url
    }

    func url(_ path: String, query: [String: String?] = [:]) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.path = components.path + path
        let items = query.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
        if !items.isEmpty {
            // sorted, so a request is the same URL every time (tests, caches)
            components.queryItems = items.sorted { $0.name < $1.name }
        }
        // URLComponents leaves "+" alone, and every server here reads it as a space
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    func request(
        _ method: String, _ path: String, query: [String: String?] = [:], json body: JSON? = nil,
        headers: [String: String] = [:], timeout: TimeInterval? = nil
    ) throws -> URLRequest {
        var request = URLRequest(url: url(path, query: query))
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body {
            request.httpBody = try body.data()
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let timeout { request.timeoutInterval = timeout }
        return request
    }
}

extension URLRequest {
    /// An `application/x-www-form-urlencoded` body, the way qBittorrent wants
    /// its POSTs, the fields in key order.
    mutating func setForm(_ fields: [String: String]) {
        setForm(fields.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
    }

    /// Fields in the order given, a key as often as it comes: Bazarr takes a
    /// list as the same key over and over.
    mutating func setForm(_ fields: [(String, String)]) {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func encoded(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text }
        httpBody = Data(fields.map { "\(encoded($0.0))=\(encoded($0.1))" }.joined(separator: "&").utf8)
        setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    }
}

/// `items` mapped concurrently, at most `width` at a time, answers in the
/// items' order. A narrow width is for the fan-outs that would otherwise ask
/// a service hundreds of things at once; the next starts as one finishes, so
/// a slow one holds a slot rather than a batch.
/// How many lookups one screen sends a service at once: enough to hide the
/// round trips, few enough that a home server's arr is not swamped by a
/// list of twenty.
let lookupWidth = 6

func boundedMap<Item: Sendable, Mapped: Sendable>(
    _ items: [Item], width: Int, _ transform: @escaping @Sendable (Item) async -> Mapped
) async -> [Mapped] {
    await withTaskGroup(of: (Int, Mapped).self) { group in
        var next = 0
        func start() {
            guard next < items.count else { return }
            let (index, item) = (next, items[next])
            next += 1
            group.addTask { (index, await transform(item)) }
        }
        for _ in 0 ..< width { start() }
        var out = [Mapped?](repeating: nil, count: items.count)
        for await (index, mapped) in group {
            out[index] = mapped
            start()
        }
        return out.compactMap { $0 }
    }
}

/// A value behind a lock, for the little shared state the clients keep.
final class Locked<Value: Sendable>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    var current: Value { withLock { $0 } }
}
