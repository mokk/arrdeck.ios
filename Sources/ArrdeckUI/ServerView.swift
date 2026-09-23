import ArrdeckData
import ArrdeckKit
import SwiftUI

/// Everything behind a saved server: its tabs whenever the session works, the
/// connection screen whenever it does not. One controller decides which, so a
/// card's 401 and a completed sign-in both flip it.
///
/// Tabs: Books · Movies · Shows · Activity · Calendar · Settings, each only
/// while its service is configured. Each tab has its own navigation stack.
public struct ServerView: View {
    @State private var controller: SessionController
    @State private var model: DashboardModel
    @State private var showingConnection = false
    private let api: LiveAPI
    private let onSwitch: () -> Void

    public init(
        profile: ServerProfile,
        transport: any HTTPTransport = ArrdeckKit.URLSessionTransport(),
        onUpdate: @escaping (ServerProfile) -> Void,
        onSwitch: @escaping () -> Void
    ) {
        let controller = SessionController(profile: profile, transport: transport, onUpdate: onUpdate)
        let api = LiveAPI(baseURL: profile.baseURL)
        self.api = api
        self.onSwitch = onSwitch
        _controller = State(initialValue: controller)
        _model = State(initialValue: DashboardModel(
            api: api,
            onSessionLost: { controller.sessionLost() }
        ))
    }

    var sessionLost: @MainActor () -> Void {
        { [controller] in controller.sessionLost() }
    }

    public var body: some View {
        Group {
            if case .unknown = controller.session {
                ProgressView("Connecting…")
            } else if controller.isUsable {
                tabs
                    // The dashboard model polls /services and the queue; its
                    // cards live on under Settings › Overview, and the library
                    // pages read its queue for download progress.
                    .task { await model.run() }
            } else {
                NavigationStack {
                    ProfileView(controller: controller)
                        .navigationTitle(controller.profile.name)
                        .toolbar { serversButton }
                }
            }
        }
        .task { await controller.refresh() }
        .sheet(isPresented: $showingConnection) {
            NavigationStack {
                ProfileView(controller: controller)
                    .navigationTitle("Connection")
            }
        }
    }

    @State private var selectedTab: AppTab = .movies

    /// TabView keeps each tab's stack alive; its own bar is hidden and ours
    /// spans the bottom. Tabs appear only for configured services, so the
    /// bar waits for /services before it knows what to show.
    var tabs: some View {
        let available = AppTab.available(configured: model.configured)
        return Group {
            if !model.servicesKnown {
                ProgressView("Connecting…")
            } else {
                TabView(selection: $selectedTab) {
                    ForEach(available, id: \.self) { tab in
                        NavigationStack { tabContent(tab) }
                            .hiddenSystemTabBar()
                            .tag(tab)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    AppTabBar(tabs: available, selected: $selectedTab)
                }
                .onAppear { if !available.contains(selectedTab) { selectedTab = available.first ?? .settings } }
            }
        }
    }

    @ViewBuilder func tabContent(_ tab: AppTab) -> some View {
        switch tab {
        case .books:
            ContentUnavailableView("Books", systemImage: "books.vertical", description: Text("Readarr support is on its way."))
                .navigationTitle("Books")
        case .movies:
            LibraryPage(app: .radarr, dashboard: model, api: api, baseURL: controller.profile.baseURL, onSessionLost: sessionLost)
        case .shows:
            LibraryPage(app: .sonarr, dashboard: model, api: api, baseURL: controller.profile.baseURL, onSessionLost: sessionLost)
        case .activity:
            ActivityView(api: api, clients: model.torrentClients, hasArr: model.hasArr, onSessionLost: sessionLost)
        case .calendar:
            CalendarScreen(api: api, onSessionLost: sessionLost)
        case .settings:
            ManageView(
                model: model, api: api, baseURL: controller.profile.baseURL,
                serverName: controller.profile.name, sessionLabel: sessionLabel,
                onSessionLost: sessionLost, onSwitchServer: onSwitch, onShowConnection: { showingConnection = true }
            )
        }
    }

    var sessionLabel: String {
        switch controller.session {
        case .open: String(localized: "open")
        case .paired, .legacy: String(localized: "signed in")
        default: ""
        }
    }

    var serversButton: some View {
        Button(action: onSwitch) {
            Label("Servers", systemImage: "server.rack")
        }
        .accessibilityIdentifier("servers")
    }
}
