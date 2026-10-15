import ArrdeckData
import Foundation

/// Adding a Prowlarr indexer from one of its 600-odd definitions: the form
/// each definition describes, a test against the live site, the add. Ported
/// from the server's indexers.py.
extension DirectBackend: IndexerAddAPI {
    public func indexerSchemas() async throws -> [IndexerSchema] {
        try await call {
            try await definitions(try registry.arr("prowlarr"))
                .compactMap(IndexerForm.schema)
                .sorted { $0.name.lowercased() < $1.name.lowercased() }
        }
    }

    public func testNewIndexer(schema: String, displayName: String, values: [String: IndexerFieldValue]) async throws {
        try await call {
            let prowlarr = try registry.arr("prowlarr")
            let payload = try await indexerPayload(prowlarr, schema: schema, displayName: displayName, values: values)
            // Prowlarr checks against the live site; its own timeout is ~100 s
            _ = try await prowlarr.send("POST", "/indexer/test", json: payload, timeout: 120)
        }
    }

    public func addIndexer(schema: String, displayName: String, values: [String: IndexerFieldValue]) async throws {
        try await call {
            let prowlarr = try registry.arr("prowlarr")
            let payload = try await indexerPayload(prowlarr, schema: schema, displayName: displayName, values: values)
            // validated against the live site on add, too
            _ = try await prowlarr.send("POST", "/indexer", json: payload, timeout: 120)
        }
    }

    /// Every definition Prowlarr has, kept an hour: they change with
    /// Prowlarr's own updates, not between two screens.
    private func definitions(_ prowlarr: KeyedClient) async throws -> [JSON] {
        try await cached("indexer_schemas", ttl: 3600) { try await prowlarr.get("/indexer/schema").array }
    }

    /// The definition with the form's values filled in, named, enabled, and
    /// given an app profile when it has none.
    private func indexerPayload(
        _ prowlarr: KeyedClient, schema name: String, displayName: String, values: [String: IndexerFieldValue]
    ) async throws -> JSON {
        guard let schema = try await definitions(prowlarr).first(where: { $0["name"].string == name }) else {
            throw APIError.refused("unknown indexer definition '\(name)'")
        }
        let fields = schema["fields"].array.map { field in
            field["name"].string.flatMap { values[$0] }.map { field.setting("value", IndexerForm.json($0)) } ?? field
        }
        let label = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        var payload = schema
            .setting("fields", .array(fields))
            .setting("name", .string(label.isEmpty ? name : label))
            .setting("enable", true)
        if (payload["appProfileId"].int ?? 0) == 0 {
            let profiles = try await prowlarr.get("/appprofile").array
            payload = payload.setting("appProfileId", JSON(profiles.first?["id"].int ?? 1))
        }
        return payload
    }
}

private enum IndexerForm {
    /// Field types the form cannot fill in: notes, tag pickers, devices.
    static let hiddenTypes: Set = ["info", "tag", "tagSelect", "device"]

    /// A definition as the form shows it: the fields a person fills in, the
    /// advanced ones left at Prowlarr's defaults.
    static func schema(_ definition: JSON) -> IndexerSchema? {
        guard let name = definition["name"].string else { return nil }
        let fields = definition["fields"].array.compactMap { field -> IndexerField? in
            guard let fieldName = field["name"].string, field["advanced"].bool != true, fieldName != "definitionFile",
                  !hiddenTypes.contains(field["type"].string ?? "textbox")
            else { return nil }
            return self.field(field, name: fieldName)
        }
        return IndexerSchema(
            name: name, transport: definition["protocol"].string, privacy: definition["privacy"].string,
            description: definition["description"].string, fields: fields
        )
    }

    static func field(_ field: JSON, name: String) -> IndexerField {
        let kind: IndexerField.Kind = switch field["type"].string ?? "textbox" {
        case "textbox", "text", "url": .text
        case "password": .password
        case "checkbox": .checkbox
        case "select": .select
        case "number": .number
        default: .other
        }
        let value = field["value"]
        let options = field["selectOptions"].array.compactMap { option -> IndexerField.Option? in
            guard let optionName = option["name"].string else { return nil }
            return IndexerField.Option(value: number(option["value"]) ?? 0, name: optionName)
        }
        return IndexerField(
            name: name, label: field["label"].string ?? name, kind: kind, defaultText: value.string ?? "",
            defaultBool: value.bool ?? false, defaultNumber: number(value), helpText: field["helpText"].string,
            options: options
        )
    }

    /// A number as the form keeps one; a checkbox's true is 1.
    static func number(_ value: JSON) -> Double? {
        if let bool = value.bool { return bool ? 1 : 0 }
        return value.double
    }

    static func json(_ value: IndexerFieldValue) -> JSON {
        switch value {
        case let .text(text): .string(text)
        case let .bool(flag): .bool(flag)
        case let .number(number): .number(number)
        }
    }
}
