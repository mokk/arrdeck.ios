import ArrdeckAPI
import Foundation
import Observation
import OpenAPIRuntime

/// One value for a Prowlarr indexer field, typed the way the definition
/// says the field is.
public enum IndexerFieldValue: Equatable, Sendable {
    case text(String)
    case bool(Bool)
    case number(Double)

    var raw: any Sendable {
        switch self {
        case let .text(value): value
        case let .bool(value): value
        case let .number(value): value == value.rounded() ? Int(value) : value
        }
    }
}

public struct IndexerField: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case text, password, checkbox, select, number, other }

    public struct Option: Equatable, Sendable {
        public var value: Double
        public var name: String
        public init(value: Double, name: String) { self.value = value; self.name = name }
    }

    public var name: String
    public var label: String
    public var kind: Kind
    public var defaultText: String
    public var defaultBool: Bool
    public var defaultNumber: Double?
    public var helpText: String?
    public var options: [Option]

    public init(name: String, label: String, kind: Kind, defaultText: String, defaultBool: Bool, defaultNumber: Double?, helpText: String?, options: [Option]) {
        self.name = name
        self.label = label
        self.kind = kind
        self.defaultText = defaultText
        self.defaultBool = defaultBool
        self.defaultNumber = defaultNumber
        self.helpText = helpText
        self.options = options
    }

    /// The value the form starts with.
    public var defaultValue: IndexerFieldValue? {
        switch kind {
        case .checkbox: .bool(defaultBool)
        case .select, .number: defaultNumber.map(IndexerFieldValue.number)
        case .text, .password, .other: defaultText.isEmpty ? nil : .text(defaultText)
        }
    }
}

/// A Prowlarr indexer definition. The endpoint returns untyped dicts —
/// Prowlarr's own schema is open-ended — so this is decoded by hand from
/// the generated container.
public struct IndexerSchema: Equatable, Sendable, Identifiable {
    public var name: String
    public var transport: String?
    public var privacy: String?
    public var description: String?
    public var fields: [IndexerField]

    public var id: String { name }

    public init(name: String, transport: String?, privacy: String?, description: String?, fields: [IndexerField]) {
        self.name = name
        self.transport = transport
        self.privacy = privacy
        self.description = description
        self.fields = fields
    }

    public init?(_ container: OpenAPIObjectContainer) {
        let raw = container.value
        guard let name = raw["name"] as? String else { return nil }
        self.name = name
        transport = raw["protocol"] as? String
        privacy = raw["privacy"] as? String
        description = raw["description"] as? String
        let rawFields = (raw["fields"] as? [Any]) ?? []
        fields = rawFields.compactMap { any -> IndexerField? in
            guard let field = any as? [String: Any], let fieldName = field["name"] as? String else { return nil }
            let type = (field["type"] as? String) ?? "textbox"
            let kind: IndexerField.Kind = switch type {
            case "textbox", "text", "url": .text
            case "password": .password
            case "checkbox": .checkbox
            case "select": .select
            case "number": .number
            default: .other
            }
            let value = field["value"]
            let options = ((field["select_options"] as? [Any]) ?? []).compactMap { any -> IndexerField.Option? in
                guard let option = any as? [String: Any], let optionName = option["name"] as? String else { return nil }
                return IndexerField.Option(value: Self.number(option["value"]) ?? 0, name: optionName)
            }
            return IndexerField(
                name: fieldName, label: (field["label"] as? String) ?? fieldName, kind: kind,
                defaultText: value as? String ?? "", defaultBool: value as? Bool ?? false,
                defaultNumber: Self.number(value), helpText: field["help_text"] as? String, options: options
            )
        }
    }

    private static func number(_ any: Any?) -> Double? {
        switch any {
        case let int as Int: Double(int)
        case let double as Double: double
        case let bool as Bool: bool ? 1 : 0
        default: nil
        }
    }
}

public protocol IndexerAddAPI: Sendable {
    func indexerSchemas() async throws -> [IndexerSchema]
    func testNewIndexer(schema: String, displayName: String, values: [String: IndexerFieldValue]) async throws
    func addIndexer(schema: String, displayName: String, values: [String: IndexerFieldValue]) async throws
}

extension LiveAPI: IndexerAddAPI {
    public func indexerSchemas() async throws -> [IndexerSchema] {
        try await call {
            switch try await client.indexer_schemas_api_v1_indexers_schemas_get() {
            case let .ok(ok): try ok.body.json.compactMap { IndexerSchema($0.additionalProperties) }
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    private func body(schema: String, displayName: String, values: [String: IndexerFieldValue]) throws -> Components.Schemas.AddIndexerIn {
        let raw: [String: (any Sendable)?] = values.mapValues { $0.raw }
        return .init(
            display_name: displayName,
            field_values: .init(additionalProperties: try OpenAPIObjectContainer(unvalidatedValue: raw)),
            schema_name: schema
        )
    }

    public func testNewIndexer(schema: String, displayName: String, values: [String: IndexerFieldValue]) async throws {
        try await call {
            switch try await client.test_new_indexer_api_v1_indexers_test_new_post(body: .json(try body(schema: schema, displayName: displayName, values: values))) {
            case .noContent: ()
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func addIndexer(schema: String, displayName: String, values: [String: IndexerFieldValue]) async throws {
        try await call {
            switch try await client.add_indexer_api_v1_indexers_post(body: .json(try body(schema: schema, displayName: displayName, values: values))) {
            case .created: ()
            case .unprocessableContent: throw APIError.unexpectedStatus(422)
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }
}

/// Two steps: pick a definition from Prowlarr's 600-odd, then fill its
/// fields, test, add.
@MainActor @Observable
public final class AddIndexerModel {
    public var filter = ""
    public private(set) var schemas: Loadable<[IndexerSchema]> = .loading
    public private(set) var schema: IndexerSchema?
    public var displayName = ""
    public var values: [String: IndexerFieldValue] = [:]
    public private(set) var note: String?
    public private(set) var noteOK = true
    public private(set) var busy = false
    public private(set) var done = false

    private let api: any IndexerAddAPI
    private let onSessionLost: @MainActor () -> Void

    public init(api: any IndexerAddAPI, onSessionLost: @escaping @MainActor () -> Void) {
        self.api = api
        self.onSessionLost = onSessionLost
    }

    /// Case-insensitive name filter, capped so the list stays scrollable.
    public var shown: [IndexerSchema] {
        let needle = filter.lowercased()
        return (schemas.value ?? []).filter { needle.isEmpty || $0.name.lowercased().contains(needle) }.prefix(60).map { $0 }
    }

    public func load() async {
        do {
            schemas = .loaded(try await api.indexerSchemas())
        } catch {
            if case .some(.unauthorized) = error as? APIError { onSessionLost(); return }
            schemas = .failed((error as? APIError)?.description ?? error.localizedDescription)
        }
    }

    public func pick(_ chosen: IndexerSchema) {
        schema = chosen
        displayName = chosen.name
        values = Dictionary(uniqueKeysWithValues: chosen.fields.compactMap { field in field.defaultValue.map { (field.name, $0) } })
        note = nil
    }

    public func back() {
        schema = nil
        note = nil
    }

    public func test() async {
        guard let schema else { return }
        await perform { try await api.testNewIndexer(schema: schema.name, displayName: displayName, values: values) }
        if noteOK { note = String(localized: "ok: test passed") }
    }

    public func add() async {
        guard let schema else { return }
        await perform { try await api.addIndexer(schema: schema.name, displayName: displayName, values: values) }
        if noteOK { done = true }
    }

    private func perform(_ work: @Sendable () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await work()
            noteOK = true
            note = nil
        } catch APIError.unauthorized {
            onSessionLost()
        } catch {
            noteOK = false
            note = (error as? APIError)?.description ?? error.localizedDescription
        }
    }
}
