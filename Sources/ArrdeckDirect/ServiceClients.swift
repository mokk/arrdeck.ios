import Foundation

/// A service whose requests carry a fixed credential header: the arrs,
/// Prowlarr, Overseerr, Bazarr, Plex, gluetun, Prometheus and Trakt. The
/// backend's per-service clients differed only in the header, the path prefix
/// and how a refusal is worded, so here they are one type.
public struct KeyedClient: Sendable {
    public let name: String
    let endpoint: Endpoint
    /// "/api/v3" for Radarr and Sonarr, "/api/v1" for the rest of the arrs,
    /// "" for services whose paths are given whole.
    let prefix: String
    let auth: [String: String]
    let http: ServiceHTTP
    /// What a 401 says, in the service's terms.
    let unauthorized: String

    /// A JSON body, or nil for an empty one (204, or a write that returns
    /// nothing).
    public func get(_ path: String, query: [String: String?] = [:], timeout: TimeInterval? = nil) async throws -> JSON {
        try await send("GET", path, query: query, timeout: timeout)
    }

    @discardableResult
    public func send(
        _ method: String, _ path: String, query: [String: String?] = [:], json body: JSON? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> JSON {
        try await raw(method, path, query: query, json: body, timeout: timeout).json()
    }

    /// The response as it came, for the few answers that are not JSON (an
    /// iCal feed, a file).
    public func raw(
        _ method: String, _ path: String, query: [String: String?] = [:], json body: JSON? = nil,
        headers: [String: String] = [:], timeout: TimeInterval? = nil
    ) async throws -> ServiceResponse {
        var request = try endpoint.request(
            method, prefix + path, query: query, json: body, headers: auth.merging(headers) { _, new in new },
            timeout: timeout
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try await http.send(request)
        try check(response)
        return response
    }

    /// An address under the service, for what the app hands to the image
    /// loader rather than fetching itself.
    public func url(_ path: String, query: [String: String?] = [:]) -> URL {
        endpoint.url(prefix + path, query: query)
    }

    func check(_ response: ServiceResponse) throws {
        switch response.status {
        case 200 ..< 300: return
        case 401, 403:
            throw ServiceUnavailable(name, unauthorized)
        default:
            throw ServiceRefused(service: name, status: response.status, message: Self.reason(in: response))
        }
    }

    /// The service's own words for a refusal: the arrs send a list of
    /// validation failures, or an object with a message.
    static func reason(in response: ServiceResponse) -> String {
        guard let body = try? response.json() else { return "" }
        if let first = body.array.first, let message = first["errorMessage"].string { return message }
        return body["message"].string ?? body["error"].string ?? body["errorMessage"].string ?? ""
    }
}

/// qBittorrent's WebUI API. Often open to the LAN through its subnet
/// whitelist; otherwise a 403 means log in with the saved credentials (a
/// cookie session) and try once more.
public actor QbittorrentClient {
    public nonisolated let name = "qbittorrent"
    let endpoint: Endpoint
    let username: String
    let password: String
    let http: ServiceHTTP

    init(endpoint: Endpoint, username: String, password: String, http: ServiceHTTP) {
        self.endpoint = endpoint
        self.username = username
        self.password = password
        self.http = http
    }

    func login() async throws {
        guard !username.isEmpty else {
            throw ServiceUnavailable(name, "403 Forbidden and no credentials configured")
        }
        var request = try endpoint.request("POST", "/api/v2/auth/login", headers: originHeaders)
        request.setForm(["username": username, "password": password])
        let response = try await http.send(request)
        guard response.status == 200, response.text.trimmingCharacters(in: .whitespacesAndNewlines) == "Ok." else {
            throw ServiceUnavailable(name, "login failed (check credentials)")
        }
    }

    /// qBittorrent refuses a login whose Referer or Origin is not its own
    /// address (its CSRF check); a browser sends them, the app has to.
    var originHeaders: [String: String] {
        let origin = endpoint.base.absoluteString
        return ["Referer": origin, "Origin": origin]
    }

    public func request(
        _ method: String, _ path: String, query: [String: String?] = [:], form: [String: String]? = nil,
        body: Data? = nil, contentType: String? = nil, timeout: TimeInterval? = nil
    ) async throws -> ServiceResponse {
        func build() throws -> URLRequest {
            var request = try endpoint.request(method, path, query: query, headers: originHeaders, timeout: timeout)
            if let form { request.setForm(form) }
            if let body {
                request.httpBody = body
                if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
            }
            return request
        }
        var response = try await http.send(try build())
        if response.status == 403 {
            try await login()
            response = try await http.send(try build())
            if response.status == 403 { throw ServiceUnavailable(name, "403 Forbidden after login") }
        }
        guard (200 ..< 300).contains(response.status) else {
            throw ServiceRefused(service: name, status: response.status, message: response.text)
        }
        return response
    }

    public func get(_ path: String, query: [String: String?] = [:]) async throws -> JSON {
        try await request("GET", path, query: query).json()
    }

    public func post(_ path: String, form: [String: String] = [:]) async throws {
        _ = try await request("POST", path, form: form)
    }

    public func version() async throws -> String {
        try await request("GET", "/api/v2/app/version").text
    }
}

/// Transmission's RPC: one POST endpoint, a session id handed out on the
/// first 409 and echoed on every request after, and optional basic auth.
public actor TransmissionClient {
    public nonisolated let name = "transmission"
    let endpoint: Endpoint
    let authorization: String?
    let http: ServiceHTTP
    var sessionID: String?

    init(endpoint: Endpoint, username: String, password: String, http: ServiceHTTP) {
        self.endpoint = endpoint
        authorization = username.isEmpty
            ? nil : "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        self.http = http
    }

    public func rpc(_ method: String, _ arguments: JSON = [:]) async throws -> JSON {
        let body: JSON = ["method": .string(method), "arguments": arguments]
        func build() throws -> URLRequest {
            var headers: [String: String] = [:]
            if let sessionID { headers["X-Transmission-Session-Id"] = sessionID }
            if let authorization { headers["Authorization"] = authorization }
            return try endpoint.request("POST", "/transmission/rpc", json: body, headers: headers)
        }
        var response = try await http.send(try build())
        if response.status == 409 {
            sessionID = response.header("X-Transmission-Session-Id")
            response = try await http.send(try build())
        }
        if response.status == 401 { throw ServiceUnavailable(name, "unauthorized (check username and password)") }
        guard (200 ..< 300).contains(response.status) else {
            throw ServiceRefused(service: name, status: response.status, message: response.text)
        }
        let payload = try response.json()
        guard payload["result"].string == "success" else {
            throw ServiceUnavailable(name, "rpc error: \(payload["result"].string ?? "?")")
        }
        return payload["arguments"]
    }
}
