import ArrdeckAPI
import Foundation

public typealias IcalSettings = Components.Schemas.IcalSettingsOut

/// The calendar subscription's switch and secret.
public protocol IcalAPI: Sendable {
    func icalSettings() async throws -> IcalSettings
    func setIcal(enabled: Bool) async throws -> IcalSettings
}

extension LiveAPI: IcalAPI {
    public func icalSettings() async throws -> IcalSettings {
        try await call {
            switch try await client.ical_settings_api_v1_ical_settings_get() {
            case let .ok(ok): try ok.body.json
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func setIcal(enabled: Bool) async throws -> IcalSettings {
        try await call {
            if enabled {
                switch try await client.ical_new_token_api_v1_ical_settings_token_post() {
                case let .ok(ok): return try ok.body.json
                case let .undocumented(code, _): throw APIError.status(code)
                }
            } else {
                switch try await client.ical_disable_api_v1_ical_settings_token_delete() {
                case let .ok(ok): return try ok.body.json
                case let .undocumented(code, _): throw APIError.status(code)
                }
            }
        }
    }
}

extension IcalSettings {
    /// The feed on this server, limited to `apps` when that is not all of them;
    /// nil while the subscription is off.
    public func url(on base: URL, apps chosen: [String]? = nil) -> URL? {
        guard enabled == true, let token, !token.isEmpty else { return nil }
        var url = base.appendingPathComponent("ical").appendingPathComponent(token).appendingPathComponent("arrdeck.ics")
        let all = apps ?? []
        if let chosen, !chosen.isEmpty, Set(chosen) != Set(all) {
            url = url.appending(queryItems: [URLQueryItem(name: "apps", value: all.filter(chosen.contains).joined(separator: ","))])
        }
        return url
    }

    /// The same address as webcal://, which Calendar opens as a subscription.
    public func webcal(on base: URL, apps chosen: [String]? = nil) -> URL? {
        guard let url = url(on: base, apps: chosen), var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = "webcal"
        return parts.url
    }
}
