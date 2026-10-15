import Foundation

/// The configured services as clients, rebuilt from the saved connections.
/// The torrent clients hold a session (a cookie, a session id), so each is
/// built once per connection and reused until that connection changes.
public final class Registry: Sendable {
    let store: any ConnectionStore
    let transport: any ServiceTransport
    let retries = RetryLog()
    private let state: Locked<State>

    struct State: Sendable {
        var connections: [String: ServiceConnection]
        var qbittorrent: (ServiceConnection, QbittorrentClient)?
        var transmission: (ServiceConnection, TransmissionClient)?
    }

    public init(store: any ConnectionStore, transport: any ServiceTransport = URLSessionServiceTransport()) {
        self.store = store
        self.transport = transport
        state = Locked(State(connections: (try? store.load()) ?? [:]))
    }

    public var connections: [String: ServiceConnection] { state.current.connections }

    public func connection(_ name: String) -> ServiceConnection {
        connections[name] ?? ServiceConnection()
    }

    public func isConfigured(_ name: String) -> Bool {
        DirectServices.isConfigured(name, connections[name])
    }

    public var configured: [String] { DirectServices.all.filter(isConfigured) }

    /// Saves one service's connection and drops whatever was built on the old
    /// one.
    public func save(_ name: String, _ connection: ServiceConnection) throws {
        var all = connections
        all[name] = connection.normalised
        try store.save(all)
        state.withLock { state in
            state.connections = all
            if name == "qbittorrent" { state.qbittorrent = nil }
            if name == "transmission" { state.transmission = nil }
        }
    }

    func http(_ name: String) -> ServiceHTTP {
        ServiceHTTP(service: name, transport: transport, retries: retries)
    }

    func endpoint(_ name: String) throws -> Endpoint {
        guard isConfigured(name), let endpoint = Endpoint(connection(name).url) else {
            throw ServiceUnavailable.notConfigured(name)
        }
        return endpoint
    }

    // MARK: - Clients

    /// Radarr, Sonarr, Readarr, Lidarr or Prowlarr.
    public func arr(_ name: String) throws -> KeyedClient {
        let prefix = ["radarr", "sonarr"].contains(name) ? "/api/v3" : "/api/v1"
        return try keyed(name, prefix: prefix, header: "X-Api-Key", unauthorized: "unauthorized (check API key)")
    }

    public func overseerr() throws -> KeyedClient {
        try keyed("overseerr", prefix: "/api/v1", header: "X-Api-Key", unauthorized: "unauthorized (check API key)")
    }

    public func bazarr() throws -> KeyedClient {
        try keyed("bazarr", prefix: "/api", header: "X-API-KEY", unauthorized: "unauthorized (check API key)")
    }

    public func plex() throws -> KeyedClient {
        try keyed("plex", prefix: "", header: "X-Plex-Token", unauthorized: "unauthorized (check the Plex token)")
    }

    public func gluetun() throws -> KeyedClient {
        try keyed("gluetun", prefix: "", header: "X-API-Key",
                  unauthorized: "unauthorized — grant this route in gluetun's auth config")
    }

    public func prometheus() throws -> KeyedClient {
        try keyed("prometheus", prefix: "", header: nil, unauthorized: "unauthorized")
    }

    public func trakt() throws -> KeyedClient {
        let name = "trakt"
        guard isConfigured(name) else { throw ServiceUnavailable.notConfigured(name) }
        let connection = connection(name)
        let endpoint = Endpoint(connection.url) ?? Endpoint("https://api.trakt.tv")!
        return KeyedClient(
            name: name, endpoint: endpoint, prefix: "",
            auth: ["trakt-api-version": "2", "trakt-api-key": connection.apiKey],
            http: http(name), unauthorized: "unauthorized (check the Trakt client id)"
        )
    }

    private func keyed(_ name: String, prefix: String, header: String?, unauthorized: String) throws -> KeyedClient {
        let endpoint = try endpoint(name)
        let key = connection(name).apiKey
        var auth: [String: String] = [:]
        if let header, !key.isEmpty { auth[header] = key }
        return KeyedClient(name: name, endpoint: endpoint, prefix: prefix, auth: auth, http: http(name),
                           unauthorized: unauthorized)
    }

    public func qbittorrent() throws -> QbittorrentClient {
        let name = "qbittorrent"
        let endpoint = try endpoint(name)
        let connection = connection(name)
        return state.withLock { state in
            if let (built, client) = state.qbittorrent, built == connection { return client }
            let client = QbittorrentClient(endpoint: endpoint, username: connection.username,
                                           password: connection.password, http: http(name))
            state.qbittorrent = (connection, client)
            return client
        }
    }

    public func transmission() throws -> TransmissionClient {
        let name = "transmission"
        let endpoint = try endpoint(name)
        let connection = connection(name)
        return state.withLock { state in
            if let (built, client) = state.transmission, built == connection { return client }
            let client = TransmissionClient(endpoint: endpoint, username: connection.username,
                                            password: connection.password, http: http(name))
            state.transmission = (connection, client)
            return client
        }
    }

    /// The version a service reports — the Connections screen's Test, and
    /// its status dots.
    public func probeVersion(_ name: String) async throws -> String {
        switch name {
        case "radarr", "sonarr", "readarr", "lidarr", "prowlarr":
            return try await arr(name).get("/system/status")["version"].string ?? "?"
        case "overseerr":
            return try await overseerr().get("/status")["version"].string ?? "?"
        case "qbittorrent":
            return try await qbittorrent().version()
        case "transmission":
            return try await transmission().rpc("session-get")["version"].string ?? "?"
        case "gluetun":
            // no version endpoint; the tunnel state is the useful signal
            return try await gluetun().get("/v1/vpn/status")["status"].string ?? "?"
        case "bazarr":
            return try await bazarr().get("/system/status")["data"]["bazarr_version"].string ?? "?"
        case "plex":
            return try await plex().get("/identity")["MediaContainer"]["version"].string ?? "?"
        case "prometheus":
            return try await prometheus().get("/api/v1/status/buildinfo")["data"]["version"].string ?? "?"
        case "trakt":
            _ = try await trakt().get("/movies/trending", query: ["limit": "1"])
            return "2" // the API version; Trakt reports none of its own
        default:
            throw ServiceUnavailable(name, "unknown service")
        }
    }
}
