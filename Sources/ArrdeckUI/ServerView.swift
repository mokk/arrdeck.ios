import ArrdeckData
import ArrdeckKit
import SwiftUI

/// Everything behind a saved server: its tabs whenever the session works, the
/// connection screen whenever it does not. One controller decides which, so a
/// card's 401 and a completed sign-in both flip it.
///
/// Tabs follow the PWA's bottom bar — Home, Popular, Downloads, Add, Manage.
/// Each tab has its own navigation stack.
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

    var tabs: some View {
        TabView {
            NavigationStack {
                DashboardView(model: model, baseURL: controller.profile.baseURL, api: api, onSessionLost: sessionLost)
                    .navigationTitle(controller.profile.name)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { serversButton }
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                showingConnection = true
                            } label: {
                                Label("Connection", systemImage: "info.circle")
                            }
                            .accessibilityIdentifier("connection")
                        }
                    }
            }
            .tabItem { Label("Home", systemImage: "house") }

            if model.has("prowlarr") {
                NavigationStack {
                    PopularView(api: api, onSessionLost: sessionLost)
                }
                .tabItem { Label("Popular", systemImage: "flame") }
            }

            NavigationStack {
                // The clients come from /services, so the screen waits for
                // that answer rather than being built with an empty set.
                if model.servicesKnown {
                    DownloadsView(api: api, clients: model.torrentClients, hasArr: model.hasArr, onSessionLost: sessionLost)
                } else {
                    ProgressView().navigationTitle("Downloads")
                }
            }
            .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }

            NavigationStack {
                if model.servicesKnown {
                    AddView(configured: model.configured, api: api, baseURL: controller.profile.baseURL,
                            hasPlex: model.has("plex"), onSessionLost: sessionLost)
                } else {
                    ProgressView().navigationTitle("Add")
                }
            }
            .tabItem { Label("Add", systemImage: "plus.circle") }

            NavigationStack {
                if model.servicesKnown {
                    ManageView(model: model, api: api, baseURL: controller.profile.baseURL, onSessionLost: sessionLost)
                } else {
                    ProgressView().navigationTitle("Manage")
                }
            }
            .tabItem { Label("Manage", systemImage: "slider.horizontal.3") }
        }
    }

    var serversButton: some View {
        Button(action: onSwitch) {
            Label("Servers", systemImage: "server.rack")
        }
        .accessibilityIdentifier("servers")
    }
}
