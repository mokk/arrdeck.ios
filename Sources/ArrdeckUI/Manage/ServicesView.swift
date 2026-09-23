import ArrdeckData
import SwiftUI

/// Per-service connection settings, with the reachability dot beside each.
struct ServicesView: View {
    @State private var model: ServicesModel

    init(api: any ManageAPI, onSessionLost: @escaping @MainActor () -> Void) {
        _model = State(initialValue: ServicesModel(api: api, onSessionLost: onSessionLost))
    }

    var body: some View {
        List {
            if let error = model.error {
                Section { ErrorNote(error) }
            } else if !model.loaded {
                Section { LoadingRow() }
            }
            ForEach(model.forms) { form in
                ServiceFormSection(form: form, status: model.status.first { $0.service.rawValue == form.name }, model: model)
            }
        }
        .dashboardListStyle()
        .navigationTitle("Connections")
        .task { await model.load() }
        .refreshable { await model.load() }
    }
}

struct ServiceFormSection: View {
    @Bindable var form: ServiceForm
    let status: ServiceStatus?
    let model: ServicesModel

    var body: some View {
        Section {
            ForEach(form.fields, id: \.self) { field in
                switch field {
                case .url:
                    TextField("http://10.0.0.154:1234 (empty = disabled)", text: $form.url)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                case .apiKey:
                    SecureField("API key", text: $form.apiKey)
                case .username:
                    TextField("Username (optional)", text: $form.username)
                        .autocorrectionDisabled()
                case .password:
                    SecureField("Password (optional)", text: $form.password)
                }
            }
            HStack {
                Button("Save") { Task { await model.save(form) } }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(!form.dirty || form.busy)
                Button("Test") { Task { await model.test(form) } }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(form.dirty || form.busy || !form.configured)
                    .help(form.dirty ? "Save first" : "Test the saved connection")
                Spacer()
                if let result = form.result {
                    Text(result).font(.caption).foregroundStyle(form.resultOK ? Color.green : Color.red).lineLimit(1)
                }
            }
        } header: {
            HStack(spacing: 8) {
                if let status {
                    Circle().fill(!status.ok ? Color.red : (status.isFlaky ? Color.orange : Color.green)).frame(width: 8, height: 8)
                }
                Text(Services.label(form.name))
                Spacer()
                Text(form.configured ? "configured" : "not configured").textCase(nil)
            }
        }
        .disabled(form.busy)
    }
}
