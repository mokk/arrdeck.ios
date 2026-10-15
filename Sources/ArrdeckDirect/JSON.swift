import Foundation

/// An upstream payload as it came: the arrs, the torrent clients and the rest
/// each answer in their own loose shapes, and most of what the app shows is a
/// handful of fields picked out of them. Reading those by name, with a missing
/// or mistyped field simply absent, follows the backend's dict handling and
/// keeps a new field upstream from failing a whole list.
public enum JSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    public subscript(key: String) -> JSON {
        if case let .object(fields) = self { fields[key] ?? .null } else { .null }
    }

    public subscript(index: Int) -> JSON {
        if case let .array(items) = self, items.indices.contains(index) { items[index] } else { .null }
    }

    public var isNull: Bool { self == .null }

    public var string: String? {
        if case let .string(value) = self { value } else { nil }
    }

    /// Whole numbers only; a fractional one is not an id or a count.
    public var int: Int? {
        if case let .number(value) = self, let whole = Int(exactly: value.rounded(.towardZero)) { whole } else { nil }
    }

    public var double: Double? {
        if case let .number(value) = self { value } else { nil }
    }

    public var bool: Bool? {
        if case let .bool(value) = self { value } else { nil }
    }

    public var array: [JSON] {
        if case let .array(items) = self { items } else { [] }
    }

    public var object: [String: JSON] {
        if case let .object(fields) = self { fields } else { [:] }
    }

    /// An ISO 8601 timestamp, with or without fractional seconds — the arrs
    /// write both, sometimes in the same payload.
    public var date: Date? {
        string.flatMap(JSON.parseDate)
    }

    static func parseDate(_ raw: String) -> Date? {
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        if let date = try? fractional.parse(raw) { return date }
        if let date = try? Date.ISO8601FormatStyle().parse(raw) { return date }
        // Transmission and a few arr fields: a date with no zone, meaning UTC
        return try? Date.ISO8601FormatStyle().parse(raw + "Z")
    }
}

extension JSON: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSON].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value):
            if let whole = Int(exactly: value) { try container.encode(whole) } else { try container.encode(value) }
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    public init(data: Data) throws {
        self = try JSONDecoder().decode(JSON.self, from: data)
    }

    public func data() throws -> Data {
        try JSONEncoder().encode(self)
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral, ExpressibleByFloatLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}

extension JSON {
    /// For building request bodies from Swift values.
    public init(_ value: Int?) { self = value.map { .number(Double($0)) } ?? .null }
    public init(_ value: String?) { self = value.map { .string($0) } ?? .null }
    public init(_ value: Bool?) { self = value.map { .bool($0) } ?? .null }
    public init(_ value: [Int]) { self = .array(value.map { .number(Double($0)) }) }

    /// A copy with one field set — the arrs' PUTs take the whole object back.
    public func setting(_ key: String, _ value: JSON) -> JSON {
        var fields = object
        fields[key] = value
        return .object(fields)
    }
}
