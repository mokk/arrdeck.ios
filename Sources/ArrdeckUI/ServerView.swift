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

    /// Every tab's stack stays mounted in a ZStack and only the selected one
    /// is visible, so switching tabs keeps scroll position and pushed screens.
    /// Not a TabView: with six tabs UIKit folds the last ones into a "More"
    /// list, and popping a pushed screen in the sixth tab landed there instead
    /// of on the tab's root. Tabs appear only for configured services, so the
    /// bar waits for /services before it knows what to show.
    var tabs: some View {
        let available = AppTab.available(configured: model.configured)
        return Group {
            if !model.servicesKnown {
                ProgressView("Connecting…")
            } else {
                ZStack {
                    ForEach(available, id: \.self) { tab in
                        // accessibilityHidden has to sit inside the stack:
                        // applied to the NavigationStack itself it is ignored
                        // and the hidden tabs stay visible to VoiceOver.
                        NavigationStack {
                            tabContent(tab)
                                .accessibilityHidden(tab != selectedTab)
                        }
                        .opacity(tab == selectedTab ? 1 : 0)
                        .allowsHitTesting(tab == selectedTab)
                        .zIndex(tab == selectedTab ? 1 : 0)
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
            LibraryPage(app: .readarr, dashboard: model, api: api, baseURL: controller.profile.baseURL, onSessionLost: sessionLost)
        case .movies:
            LibraryPage(app: .radarr, dashboard: model, api: api, baseURL: controller.profile.baseURL, onSessionLost: sessionLost)
        case .shows:
            LibraryPage(app: .sonarr, dashboard: model, api: api, baseURL: controller.profile.baseURL, onSessionLost: sessionLost)
        case .activity:
            ActivityView(api: api, clients: model.torrentClients, hasArr: model.hasArr,
                         baseURL: controller.profile.baseURL, hasPlex: model.has("plex"), onSessionLost: sessionLost)
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
