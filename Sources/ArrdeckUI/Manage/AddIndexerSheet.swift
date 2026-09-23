import ArrdeckData
import SwiftUI

/// Pick a Prowlarr definition, fill its fields, test, add.
struct AddIndexerSheet: View {
    @State private var model: AddIndexerModel
    let dismiss: () -> Void

    init(api: any IndexerAddAPI, onSessionLost: @escaping @MainActor () -> Void, dismiss: @escaping () -> Void) {
        self.dismiss = dismiss
        _model = State(initialValue: AddIndexerModel(api: api, onSessionLost: onSessionLost))
    }

    var body: some View {
        NavigationStack {
            Group {
                if let schema = model.schema {
                    form(schema)
                } else {
                    picker
                }
            }
            .navigationTitle(model.schema.map { "Add \($0.name)" } ?? "Add indexer")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if model.schema != nil {
                        Button("Back") { model.back() }
                    } else {
                        Button("Cancel") { dismiss() }
                    }
                }
                if model.schema != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(model.busy ? "…" : "Add") { Task { await model.add() } }
                            .disabled(model.busy || model.displayName.isEmpty)
                    }
                }
            }
            .task { await model.load() }
            .onChange(of: model.done) { _, done in if done { dismiss() } }
        }
    }

    var picker: some View {
        List {
            switch model.schemas {
            case .loading:
                Section { LoadingRow(); Text("Loading definitions…").font(.caption).foregroundStyle(.secondary) }
            case let .failed(reason):
                Section { ErrorNote(reason) }
            case .loaded:
                Section {
                    if model.shown.isEmpty { EmptyNote("No matches") }
                    ForEach(model.shown) { schema in
                        Button { model.pick(schema) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(schema.name).font(.subheadline.weight(.medium))
                                Text([schema.privacy, schema.transport].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Pick a Prowlarr indexer definition")
                }
            }
        }
        .searchable(text: $model.filter, prompt: "Search indexers…")
    }

    func form(_ schema: IndexerSchema) -> some View {
        Form {
            if let description = schema.description, !description.isEmpty {
                Section { Text(description).font(.caption).foregroundStyle(.secondary) }
            }
            Section {
                TextField("Name", text: $model.displayName)
                ForEach(schema.fields, id: \.name) { field in
                    IndexerFieldRow(field: field, value: binding(field))
                }
            }
            if let note = model.note {
                Section { Text(note).font(.subheadline).foregroundStyle(model.noteOK ? Color.green : Color.red) }
            }
            Section {
                Button(model.busy ? "Testing…" : "Test") { Task { await model.test() } }
                    .disabled(model.busy)
            }
        }
    }

    func binding(_ field: IndexerField) -> Binding<IndexerFieldValue?> {
        Binding(get: { model.values[field.name] }, set: { model.values[field.name] = $0 })
    }
}

struct IndexerFieldRow: View {
    let field: IndexerField
    @Binding var value: IndexerFieldValue?

    var text: Binding<String> {
        Binding(
            get: { if case let .text(t)? = value { t } else { "" } },
            set: { value = $0.isEmpty ? nil : .text($0) }
        )
    }

    var number: Binding<String> {
        Binding(
            get: { if case let .number(n)? = value { n == n.rounded() ? String(Int(n)) : String(n) } else { "" } },
            set: { value = Double($0).map(IndexerFieldValue.number) }
        )
    }

    var body: some View {
        switch field.kind {
        case .checkbox:
            Toggle(field.label, isOn: Binding(
                get: { if case let .bool(b)? = value { b } else { false } },
                set: { value = .bool($0) }
            ))
        case .select:
            Picker(field.label, selection: Binding(
                get: { if case let .number(n)? = value { n } else { field.options.first?.value ?? 0 } },
                set: { value = .number($0) }
            )) {
                ForEach(field.options, id: \.value) { option in Text(option.name).tag(option.value) }
            }
        case .number:
            HStack {
                Text(field.label)
                Spacer()
                TextField(field.helpText ?? "", text: number).multilineTextAlignment(.trailing).frame(maxWidth: 140)
            }
        case .password:
            SecureField(field.label, text: text)
        case .text, .other:
            TextField(field.label, text: text, prompt: Text(field.helpText ?? field.label))
                .autocorrectionDisabled()
        }
    }
}
