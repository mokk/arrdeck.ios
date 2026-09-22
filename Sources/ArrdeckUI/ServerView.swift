import ArrdeckData
import ArrdeckKit
import SwiftUI

/// The screen behind a saved server: the dashboard whenever the session
/// works, the connection screen whenever it does not. One controller decides
/// which, so a card's 401 and a completed sign-in both flip it.
public struct ServerView: View {
    @State private var controller: SessionController
    @State private var model: DashboardModel
    @State private var showingConnection = false
    private let api: LiveAPI

    public init(
        profile: ServerProfile,
        transport: any HTTPTransport = ArrdeckKit.URLSessionTransport(),
        onUpdate: @escaping (ServerProfile) -> Void
    ) {
        let controller = SessionController(profile: profile, transport: transport, onUpdate: onUpdate)
        let api = LiveAPI(baseURL: profile.baseURL)
        self.api = api
        _controller = State(initialValue: controller)
        _model = State(initialValue: DashboardModel(
            api: api,
            onSessionLost: { controller.sessionLost() }
        ))
    }

    public var body: some View {
        Group {
            if case .unknown = controller.session {
                ProgressView("Connecting…")
            } else if controller.isUsable {
                DashboardView(
                    model: model, baseURL: controller.profile.baseURL, api: api,
                    onSessionLost: { [controller] in controller.sessionLost() }
                )
                    .toolbar {
                        Button {
                            showingConnection = true
                        } label: {
                            Label("Connection", systemImage: "info.circle")
                        }
                        .accessibilityIdentifier("connection")
                    }
            } else {
                ProfileView(controller: controller)
            }
        }
        .navigationTitle(controller.profile.name)
        .task { await controller.refresh() }
        .sheet(isPresented: $showingConnection) {
            NavigationStack {
                ProfileView(controller: controller)
                    .navigationTitle("Connection")
            }
        }
    }
}
