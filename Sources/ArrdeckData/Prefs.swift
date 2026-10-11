import ArrdeckAPI
import Foundation
import OpenAPIRuntime

/// One value in the server's preference set, which is a flat object of
/// scalars and arrays of strings. Typed rather than `Any` so a key this app
/// does not know can be sent back exactly as it arrived.
public enum PrefValue: Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case strings([String])

    init?(raw: (any Sendable)?) {
        switch raw {
        case nil: self = .null
        // before the numbers: a Bool must not be read as 0 or 1
        case let value as Bool: self = .bool(value)
        case let value as String: self = .string(value)
        case let value as Int: self = .int(value)
        case let value as Double: self = .double(value)
        case let value as [(any Sendable)?]:
            let strings = value.compactMap { $0 as? String }
            guard strings.count == value.count else { return nil }
            self = .strings(strings)
        default: return nil
        }
    }

    var raw: (any Sendable)? {
        switch self {
        case let .string(value): value
        case let .int(value): value
        case let .double(value): value
        case let .bool(value): value
        case .null: nil
        case let .strings(value): value.map { $0 as (any Sendable)? }
        }
    }

    public var string: String? {
        if case let .string(value) = self { value } else { nil }
    }

    public var strings: [String]? {
        if case let .strings(value) = self { value } else { nil }
    }
}

/// What the server holds: the values, and the unix-millisecond time of the
/// write that produced them (0 until something was written).
public struct StoredPrefs: Equatable, Sendable {
    public var values: [String: PrefValue]
    public var updatedAt: Int

    public init(values: [String: PrefValue] = [:], updatedAt: Int = 0) {
        self.values = values
        self.updatedAt = updatedAt
    }
}

/// The display preferences shared between a household's devices.
public protocol PrefsAPI: Sendable {
    func prefs() async throws -> StoredPrefs
    /// Replaces the whole set unless the server holds a newer one. Always
    /// returns what is now stored: an `updatedAt` greater than the one sent
    /// means the write lost and the returned values are the ones to adopt.
    func putPrefs(values: [String: PrefValue], updatedAt: Int) async throws -> StoredPrefs
}

extension LiveAPI: PrefsAPI {
    public func prefs() async throws -> StoredPrefs {
        try await call {
            switch try await client.get_prefs_api_v1_prefs_get() {
            case let .ok(ok): StoredPrefs(try ok.body.json)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func putPrefs(values: [String: PrefValue], updatedAt: Int) async throws -> StoredPrefs {
        try await call {
            let container = try OpenAPIObjectContainer(unvalidatedValue: values.mapValues(\.raw))
            return switch try await client.put_prefs_api_v1_prefs_put(
                body: .json(.init(updated_at: updatedAt, values: .init(additionalProperties: container)))
            ) {
            case let .ok(ok): StoredPrefs(try ok.body.json)
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }
}

extension StoredPrefs {
    init(_ out: Components.Schemas.PrefsOut) {
        // a value of a shape the server promises not to send is left out
        // rather than failing the whole read
        let raw = out.values?.additionalProperties.value ?? [:]
        self.init(values: raw.compactMapValues { PrefValue(raw: $0) }, updatedAt: out.updated_at ?? 0)
    }
}
