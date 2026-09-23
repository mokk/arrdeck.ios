import ArrdeckAPI
import ArrdeckData
import Foundation
import OpenAPIRuntime
import Testing

@Suite struct IndexerSchemaTests {
    /// Decoded from JSON, exactly as the generated container arrives.
    func container(_ json: String) throws -> OpenAPIObjectContainer {
        try JSONDecoder().decode(OpenAPIObjectContainer.self, from: Data(json.utf8))
    }

    @Test func parsesProwlarrsFieldShapes() throws {
        let schema = try #require(IndexerSchema(try container("""
        {"name": "TorrentLeech", "protocol": "torrent", "privacy": "private", "description": "TL",
         "fields": [
           {"name": "username", "label": "Username", "type": "textbox", "value": null, "help_text": null, "select_options": []},
           {"name": "freeleech", "label": "Freeleech only", "type": "checkbox", "value": false, "help_text": null, "select_options": []},
           {"name": "sort", "label": "Sort", "type": "select", "value": 0, "help_text": null,
            "select_options": [{"value": 0, "name": "created"}, {"value": 1, "name": "title"}]},
           {"name": "torrentBaseSettings.seedRatio", "label": "Seed Ratio", "type": "number", "value": null, "help_text": "ratio", "select_options": []}
         ]}
        """)))
        #expect(schema.name == "TorrentLeech")
        #expect(schema.privacy == "private")
        #expect(schema.transport == "torrent")
        #expect(schema.fields.map(\.kind) == [.text, .checkbox, .select, .number])
        #expect(schema.fields[2].options.map(\.name) == ["created", "title"])
        #expect(schema.fields[2].options[1].value == 1)
        #expect(schema.fields[1].defaultBool == false)
        #expect(schema.fields[3].helpText == "ratio")
    }

    @Test func missingNameIsNotASchema() throws {
        #expect(IndexerSchema(try container(#"{"protocol": "torrent"}"#)) == nil)
    }
}

actor FakeIndexerAPI: IndexerAddAPI {
    var failTest = false
    private(set) var calls: [String] = []
    func set(failTest: Bool) { self.failTest = failTest }
    func count(_ c: String) -> Int { calls.filter { $0 == c }.count }

    func indexerSchemas() async throws -> [IndexerSchema] {
        calls.append("schemas")
        return [
            IndexerSchema(name: "Alpha", transport: "torrent", privacy: "public", description: nil,
                          fields: [IndexerField(name: "url", label: "URL", kind: .text, defaultText: "", defaultBool: false, defaultNumber: nil, helpText: nil, options: [])]),
            IndexerSchema(name: "Beta", transport: "usenet", privacy: "private", description: "b",
                          fields: [IndexerField(name: "sort", label: "Sort", kind: .select, defaultText: "", defaultBool: false, defaultNumber: 1, helpText: nil,
                                                options: [.init(value: 0, name: "a"), .init(value: 1, name: "b")])]),
        ]
    }
    func testNewIndexer(schema: String, displayName: String, values: [String: IndexerFieldValue]) async throws {
        calls.append("test-\(schema)-\(displayName)")
        if failTest { throw APIError.unexpectedStatus(400) }
    }
    func addIndexer(schema: String, displayName: String, values: [String: IndexerFieldValue]) async throws {
        calls.append("add-\(schema)-\(displayName)-\(values.keys.sorted().joined(separator: ","))")
    }
}

@MainActor
@Suite struct AddIndexerModelTests {
    @Test func filtersPicksAndAdds() async {
        let api = FakeIndexerAPI()
        let model = AddIndexerModel(api: api, onSessionLost: {})
        await model.load()
        #expect(model.shown.map(\.name) == ["Alpha", "Beta"])
        model.filter = "be"
        #expect(model.shown.map(\.name) == ["Beta"])

        model.pick(model.shown[0])
        #expect(model.displayName == "Beta")
        #expect(model.values["sort"] == .number(1), "select defaults come from the schema")
        model.values["sort"] = .number(0)
        await model.test()
        #expect(model.note == "ok: test passed")
        await api.set(failTest: true)
        await model.test()
        #expect(model.note == "HTTP 400")
        #expect(!model.noteOK)
        await model.add()
        #expect(await api.count("add-Beta-Beta-sort") == 1)
        #expect(model.done)

        model.back()
        #expect(model.schema == nil)
    }
}
