import ArrdeckData
import SwiftUI

/// Settings → Display: how the app looks and behaves on this device. The sort
/// menu changes the same layouts; this is every choice in one place.
struct DisplaySettingsView: View {
    let configured: Set<String>
    let notifications: (any NotificationsAPI)?

    @AppStorage(DisplayKeys.startTab) private var startTab = ""
    @AppStorage(DisplayKeys.tabOrder) private var tabOrder = ""
    @AppStorage(DisplayKeys.hiddenTabs) private var hiddenTabs = ""
    @AppStorage(DisplayKeys.dates) private var dates: DateStyle = .relative
    @AppStorage(DisplayKeys.sizes) private var sizes: SizeStyle = .binary
    @AppStorage(DisplayKeys.spoilers) private var spoilers: Spoilers = .off
    @AppStorage(DisplayKeys.confirm) private var confirm: ConfirmPolicy = .deletes

    var apps: [ArrApp] { [.readarr, .radarr, .sonarr].filter { configured.contains($0.rawValue) } }
    var allTabs: [AppTab] { AppTab.arrange(AppTab.available(configured: configured), order: AppTab.list(tabOrder), hidden: []) }
    var hidden: Set<AppTab> { Set(AppTab.list(hiddenTabs)) }

    var body: some View {
        Form {
            Section("Tabs") {
                Picker("Open on", selection: $startTab) {
                    Text("Default").tag("")
                    ForEach(allTabs.filter { !hidden.contains($0) }, id: \.self) { Text($0.label).tag($0.rawValue) }
                }
                ForEach(allTabs, id: \.self) { tab in
                    HStack {
                        Label(tab.label, systemImage: tab.symbol)
                            .foregroundStyle(hidden.contains(tab) ? .secondary : .primary)
                        Spacer()
                        if tab != .settings {
                            Button {
                                var next = hidden
                                if next.contains(tab) { next.remove(tab) } else { next.insert(tab) }
                                hiddenTabs = AppTab.allCases.filter(next.contains).map(\.rawValue).joined(separator: ",")
                            } label: {
                                Image(systemName: hidden.contains(tab) ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(hidden.contains(tab) ? Text("Show \(tab.label)") : Text("Hide \(tab.label)"))
                        }
                    }
                }
                .onMove { from, to in
                    var next = allTabs
                    next.move(fromOffsets: from, toOffset: to)
                    tabOrder = next.map(\.rawValue).joined(separator: ",")
                }
            }
            ForEach(apps, id: \.self) { app in
                LibraryDisplaySection(app: app)
            }
            Section("Formatting") {
                Picker("Dates", selection: $dates) {
                    ForEach(DateStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Sizes", selection: $sizes) {
                    ForEach(SizeStyle.allCases, id: \.self) { Text(verbatim: $0.label).tag($0) }
                }
            }
            Section {
                Picker("Spoiler protection", selection: $spoilers) {
                    ForEach(Spoilers.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("Ask before", selection: $confirm) {
                    ForEach(ConfirmPolicy.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            } header: {
                Text("Behaviour")
            } footer: {
                Text("Spoiler protection hides the titles and summaries of episodes Plex has not seen you watch; tap one to show it. Deleting a title always asks whether to keep its files.")
            }
            if let notifications {
                Section {
                    NavigationLink {
                        NotificationSettingsView(api: notifications)
                    } label: { Label("Notifications", systemImage: "bell") }
                }
            }
            Section {
            } footer: {
                Text("These choices are kept on this device only. Drag the tabs to reorder them.")
            }
        }
        .alwaysEditing()
        .navigationTitle("Display")
    }
}

private struct LibraryDisplaySection: View {
    let app: ArrApp
    @AppStorage private var layout: LibraryLayout
    @AppStorage private var unmonitored: UnmonitoredMode

    init(app: ArrApp) {
        self.app = app
        _layout = AppStorage(wrappedValue: .posters, DisplayKeys.layout(app))
        _unmonitored = AppStorage(wrappedValue: .show, DisplayKeys.unmonitored(app))
    }

    var title: String {
        switch app {
        case .radarr: String(localized: "Movies")
        case .sonarr: String(localized: "Shows")
        case .readarr: String(localized: "Books")
        }
    }

    var body: some View {
        Section(title) {
            Picker("Layout", selection: $layout) {
                ForEach(LibraryLayout.options(for: app), id: \.self) { Text($0.label).tag($0) }
            }
            Picker("Unmonitored titles", selection: $unmonitored) {
                ForEach(UnmonitoredMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
        }
    }
}

/// The server's push settings. This app cannot receive web push itself; these
/// are the defaults every browser subscribed to arrdeck follows.
struct NotificationSettingsView: View {
    @State private var model: NotificationSettingsModel
    @State private var quietOn = false
    @State private var quietStart = Date()
    @State private var quietEnd = Date()

    init(api: any NotificationsAPI) {
        _model = State(initialValue: NotificationSettingsModel(api: api))
    }

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    var body: some View {
        Form {
            switch model.events {
            case .loading: LoadingRow()
            case let .failed(reason): ErrorNote(reason)
            case let .loaded(events):
                Section {
                    ForEach(events.available, id: \.key) { event in
                        Toggle(event.label, isOn: Binding(
                            get: { model.enabled.contains(event.key) },
                            set: { on in Task { await model.set(event.key, on: on) } }
                        ))
                    }
                } header: {
                    Text("Events")
                } footer: {
                    Text("What arrdeck pushes to the browsers subscribed to it. This app cannot receive web push itself.")
                }
                Section {
                    Toggle("Quiet hours", isOn: $quietOn)
                    if quietOn {
                        DatePicker("From", selection: $quietStart, displayedComponents: .hourAndMinute)
                        DatePicker("Until", selection: $quietEnd, displayedComponents: .hourAndMinute)
                    }
                } footer: {
                    Text("Nothing is pushed in this window; it follows this device's time zone.")
                }
            }
        }
        .navigationTitle("Notifications")
        .task {
            await model.load()
            if let rules = model.rules, let start = rules.quiet_start, !start.isEmpty,
               let from = Self.clock.date(from: start), let until = Self.clock.date(from: rules.quiet_end ?? "") {
                quietStart = from
                quietEnd = until
                quietOn = true
            }
        }
        .onChange(of: quietOn) { _, _ in saveQuiet() }
        .onChange(of: quietStart) { _, _ in if quietOn { saveQuiet() } }
        .onChange(of: quietEnd) { _, _ in if quietOn { saveQuiet() } }
    }

    func saveQuiet() {
        let start = quietOn ? Self.clock.string(from: quietStart) : ""
        let end = quietOn ? Self.clock.string(from: quietEnd) : ""
        Task { await model.setQuiet(start: start, end: end) }
    }
}

private extension View {
    /// Keeps the tab list's drag handles showing; iOS only.
    @ViewBuilder func alwaysEditing() -> some View {
        #if os(iOS)
        environment(\.editMode, .constant(.active))
        #else
        self
        #endif
    }
}
