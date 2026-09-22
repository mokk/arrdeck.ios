import Foundation

/// One upstream service's slice of an aggregate response.
///
/// The backend never fails an aggregate because a service behind it is down:
/// every slice arrives at HTTP 200 as `{ok, data, error, stale_age_seconds}`,
/// and a dead service yields ok=false — with its last good data and an age
/// when the cache still had one. Three states fall out of that, and every
/// card renders them the same way: healthy shows the data, stale shows the
/// data under an age note, offline shows the reason.
public enum Block<Value: Sendable & Equatable>: Sendable, Equatable {
    case healthy(Value)
    case stale(Value, age: TimeInterval)
    case offline(String)

    public init(ok: Bool, data: Value?, error: String?, staleAgeSeconds: Double?) {
        switch (ok, data) {
        case let (true, value?): self = .healthy(value)
        case let (false, value?): self = .stale(value, age: staleAgeSeconds ?? 0)
        case (_, nil): self = .offline(error ?? "no data")
        }
    }

    public var value: Value? {
        switch self {
        case let .healthy(value), let .stale(value, _): value
        case .offline: nil
        }
    }

    public var staleAge: TimeInterval? {
        if case let .stale(_, age) = self { age } else { nil }
    }

    public var offlineReason: String? {
        if case let .offline(reason) = self { reason } else { nil }
    }
}

/// The wire shape shared by every generated `ServiceBlock_*` struct.
/// Conformances are declared per generated type in Models.swift. While the
/// generator was dropping nullable fields, none of those structs had `data`,
/// `error` or `stale_age_seconds` — a regression that now fails to compile
/// instead of shipping cards that can never show anything.
public protocol ServiceBlockShape {
    associatedtype Payload: Sendable & Equatable
    var ok: Bool { get }
    var data: Payload? { get }
    var error: String? { get }
    var stale_age_seconds: Double? { get }
}

extension Block {
    public init<Shape: ServiceBlockShape>(_ shape: Shape) where Shape.Payload == Value {
        self.init(
            ok: shape.ok, data: shape.data, error: shape.error,
            staleAgeSeconds: shape.stale_age_seconds
        )
    }
}

/// A fetch's lifecycle around a value: not yet answered, answered, or the
/// call itself failed. `failed` means arrdeck could not be reached or refused
/// — distinct from a Block's `offline`, which is arrdeck reporting that
/// something behind it is.
public enum Loadable<Value: Sendable & Equatable>: Sendable, Equatable {
    case loading
    case loaded(Value)
    case failed(String)

    public var value: Value? {
        if case let .loaded(value) = self { value } else { nil }
    }
}

extension Loadable {
    /// One key's slice of a loaded dictionary, keeping the outer lifecycle.
    /// A key the backend did not answer for at all is a failure of that
    /// slice, not an offline service.
    public func slice<Key: Hashable & Sendable, Inner: Sendable & Equatable>(
        _ key: Key
    ) -> Loadable<Inner> where Value == [Key: Inner] {
        switch self {
        case .loading: .loading
        case let .failed(reason): .failed(reason)
        case let .loaded(dict): dict[key].map(Loadable<Inner>.loaded) ?? .failed("missing \(key)")
        }
    }
}
