import ArrdeckData
import SwiftUI

/// Settings → Display: how the app looks and behaves on this device. The
/// sort menu changes the same layouts; this is every choice in one place.
struct DisplaySettingsView: View {
    let configured: Set<String>

    @AppStorage(DisplayKeys.startTab) private var startTab = ""
    @AppStorage(DisplayKeys.tabOrder) private var tabOrder = ""
    @AppStorage(DisplayKeys.hiddenTabs) private var hiddenTabs = ""
    @AppStorage(DisplayKeys.dates) private var dates: DateStyle = .relative
    @AppStorage(DisplayKeys.sizes) private var sizes: SizeStyle = .binary
    @AppStorage(DisplayKeys.spoilers) private var spoilers: Spoilers = .off
    @AppStorage(DisplayKeys.confirm) private var confirm: ConfirmPolicy = .deletes
    @AppStorage(DisplayKeys.liveActivity) private var liveActivity = true

    var apps: [LibraryApp] { [.readarr, .radarr, .sonarr, .lidarr].filter { configured.contains($0.rawValue) } }
    var allTabs: [AppTab] { AppTab.arrange(AppTab.available(configured: configured), order: AppTab.list(tabOrder), hidden: []) }
    var hidden: Set<AppTab> { Set(AppTab.list(hiddenTabs)) }

    @State private var theme = ThemeStore.shared
    @State private var language = AppLanguage.stored()

    var body: some View {
        Form {
            ListPageHeading(title: String(localized: "Display"))
            Section {
                Picker("Language", selection: $language) {
                    ForEach(AppLanguage.allCases, id: \.self) { Text(verbatim: $0.label).tag($0) }
                }
                .onChange(of: language) { _, chosen in AppLanguage.choose(chosen) }
            } footer: {
                // iOS fixes an app's language at launch
                if language != AppLanguage.atLaunch {
                    Text("Close arrdeck and open it again to switch language.")
                }
            }
            Section {
                ForEach(Palette.allCases, id: \.self) { palette in
                    Button { theme.palette = palette } label: { PaletteRow(palette: palette, selected: theme.palette == palette) }
                        .buttonStyle(.plain)
                }
                Picker("Appearance", selection: $theme.appearance) {
                    ForEach(Appearance.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .disabled(theme.palette.darkOnly)
            } header: {
                Text("Theme")
            } footer: {
                if theme.palette.darkOnly {
                    Text("\(theme.palette.name) has no light variant, so it always shows dark.")
                }
            }
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
            // not behind os(iOS), though only a phone has one: the catalog
            // check extracts strings from the macOS build
            Section {
                Toggle("Live Activity", isOn: $liveActivity)
            } footer: {
                Text("While arrdeck is open and something is downloading, its progress shows on the Lock Screen and in the Dynamic Island. Set on this device only.")
            }
            Section {
            } footer: {
                Text("Drag the tabs to reorder them.")
            }
        }
        .alwaysEditing()
        .themedList()
        .chromePage()
        .navigationTitle("Display")
        .pageTitle()
    }
}

private struct LibraryDisplaySection: View {
    let app: LibraryApp
    @AppStorage private var layout: LibraryLayout
    @AppStorage private var unmonitored: UnmonitoredMode

    init(app: LibraryApp) {
        self.app = app
        _layout = AppStorage(wrappedValue: .posters, DisplayKeys.layout(app))
        _unmonitored = AppStorage(wrappedValue: .show, DisplayKeys.unmonitored(app))
    }

    var body: some View {
        Section(app.label) {
            Picker("Layout", selection: $layout) {
                ForEach(LibraryLayout.options(for: app), id: \.self) { Text($0.label).tag($0) }
            }
            Picker("Unmonitored titles", selection: $unmonitored) {
                ForEach(UnmonitoredMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
        }
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

/// A palette with a strip of its colours in the mode it would show in.
private struct PaletteRow: View {
    let palette: Palette
    let selected: Bool
    @Environment(\.colorScheme) private var scheme

    var tokens: PaletteTokens? {
        scheme == .light ? (palette.light ?? palette.dark) : palette.dark
    }

    var subtitle: String {
        if palette.darkOnly { return String(localized: "Dark only") }
        return palette.variants ?? String(localized: "Light · Dark")
    }

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 3) {
                ForEach(swatches, id: \.self) { color in
                    Circle().fill(color).frame(width: 14, height: 14)
                }
            }
            .padding(6)
            .background(tokens.map { Color(hex: $0.background) } ?? Color.grouped, in: Capsule())
            .overlay(Capsule().stroke(.quaternary))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: palette.name).font(.body)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if selected { Image(systemName: "checkmark").foregroundStyle(Color.accent).fontWeight(.semibold) }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    var swatches: [Color] {
        guard let t = tokens else { return [.accentColor, .green, .orange, .red] }
        return [t.accent, t.success, t.warning, t.danger].map { Color(hex: $0) }
    }
}
