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

// MARK: - Reading loose JSON the way Python did

extension JSON {
    /// Python's truthiness, for the `or` chains the server's mapping is
    /// written in: null, false, 0, "" and empty containers are all "absent".
    var truthy: Bool {
        switch self {
        case .null: false
        case let .bool(flag): flag
        case let .number(number): number != 0
        case let .string(text): !text.isEmpty
        case let .array(items): !items.isEmpty
        case let .object(fields): !fields.isEmpty
        }
    }

    /// Text, with an empty string as missing — Python's `value or None`.
    var nonEmpty: String? {
        string.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `value or None` for a count or an id: the arrs send 0 for unknown.
    var nonZero: Int? {
        int.flatMap { $0 == 0 ? nil : $0 }
    }

    /// A whole number, or a fractional one cut down: Prowlarr's averages and
    /// the torrent clients' counters are not always integral.
    var whole: Int? {
        int ?? double.map { Int($0) }
    }

    /// The year at the front of a date the services write as text, when its
    /// first four characters are digits.
    var year: Int? {
        guard let raw = string, raw.count >= 4 else { return nil }
        let head = raw.prefix(4)
        guard head.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(head)
    }

    /// A scalar as Python's f-strings printed it: whole numbers without a
    /// fraction, null as None.
    var printed: String {
        switch self {
        case let .string(text): text
        case let .number(value): Int(exactly: value).map(String.init) ?? String(value)
        case let .bool(flag): flag ? "True" : "False"
        case .null: "None"
        case .array, .object: (try? data()).map { String(decoding: $0, as: UTF8.self) } ?? ""
        }
    }
}

extension [JSON] {
    /// The items by their "id", a repeated id's last one winning, as the
    /// server's `{x["id"]: x for x in items}` had them.
    var byID: [Int: JSON] {
        var out: [Int: JSON] = [:]
        for item in self {
            if let id = item["id"].int { out[id] = item }
        }
        return out
    }
}
