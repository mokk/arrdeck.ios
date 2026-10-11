import ArrdeckData
import ArrdeckKit
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Everything behind a saved server: its tabs whenever the session works, the
/// connection screen whenever it does not. One controller decides which, so a
/// card's 401 and a completed sign-in both flip it.
///
/// Tabs: Books · Movies · Shows · Music · Activity · Calendar · Settings, each only
/// while its service is configured. Each tab has its own navigation stack.
public struct ServerView: View {
    @State private var controller: SessionController
    @State private var model: DashboardModel
    @State private var showingConnection = false
    /// State, not a plain let: SwiftUI re-runs init whenever the server list
    /// re-renders (every profile update does), and a fresh client would be
    /// bound to that throwaway init's router rather than the controller's.
    @State private var api: LiveAPI
    private let onSwitch: () -> Void

    public init(
        profile: ServerProfile,
        transport: any HTTPTransport = ArrdeckKit.URLSessionTransport(),
        onUpdate: @escaping (ServerProfile) -> Void,
        onSwitch: @escaping () -> Void
    ) {
        let controller = SessionController(profile: profile, transport: transport, onUpdate: onUpdate)
        // routed: the home address while it answers, the primary otherwise
        let api = LiveAPI(router: controller.router)
        _api = State(initialValue: api)
        self.onSwitch = onSwitch
        _controller = State(initialValue: controller)
        _model = State(initialValue: DashboardModel(
            api: api,
            onSessionLost: { controller.sessionLost() }
        ))
        _feed = State(initialValue: ActivityFeedModel(api: api, onSessionLost: { controller.sessionLost() }))
        _prefsSync = State(initialValue: PrefsSyncModel(api: api, profileID: profile.id, onApplied: { ThemeStore.shared.reload() }))
    }

    /// What happened since Activity was last opened — the badge on its tab.
    @State private var feed: ActivityFeedModel
    /// Settings → Display, kept in step with the server's copy so the choices
    /// follow you to your other devices.
    @State private var prefsSync: PrefsSyncModel

    var sessionLost: @MainActor () -> Void {
        { [controller] in controller.sessionLost() }
    }

    public var body: some View {
        Group {
            if case .unknown = controller.session {
                ProgressView("Connecting…")
            } else if controller.isUsable {
                tabs
                    .confirmDialog(confirmCenter)
                    .onContinueUserActivity(spotlightActivity) { activity in
                        if let id = activity.userInfo?[spotlightIdentifierKey] as? String,
                           let ref = SpotlightIndexer.ref(from: id) {
                            spotlit = SpotlightTarget(ref: ref)
                        }
                    }
                    .sheet(item: $spotlit) { target in
                        NavigationStack {
                            MediaDestination(ref: target.ref, api: api, baseURL: controller.activeURL,
                                             hasPlex: model.has("plex"), onSessionLost: sessionLost)
                                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { spotlit = nil } } }
                        }
                    }
                    // The dashboard model polls /services and the queue; its
                    // cards live on under Settings › Overview, and the library
                    // pages read its queue for download progress.
                    .task { await model.run() }
                    .task { await feed.run() }
                    // the widgets' snapshot and the Live Activity, from the same polls
                    .background { GlanceFeed(model: model, server: controller.profile.name) }
            } else {
                NavigationStack {
                    ProfileView(controller: controller)
                        .navigationTitle(controller.profile.name)
                        .toolbar { serversButton }
                }
            }
        }
        .task { await controller.refresh() }
        .task {
            LastProfile.record(controller.profile)
            if let expiry = Self.expiry { await ExpiryReminder.schedule(expiry) }
        }
        .sheet(isPresented: $showingConnection) {
            NavigationStack {
                ProfileView(controller: controller)
                    .navigationTitle("Connection")
            }
        }
        .task { await controller.watchNetwork() }
        .task(id: syncsPrefs) {
            guard syncsPrefs else { return }
            await prefsSync.run()
        }
        .onChange(of: scenePhase) { _, phase in
            // back from the background, perhaps somewhere else
            if phase == .active {
                controller.reroute()
                prefsSync.refreshIfStale()
            }
        }
    }

    @Environment(\.scenePhase) private var scenePhase

    /// Whether the display preferences are kept in step with the server: while
    /// the backend answers this device (until then there is no copy to read and
    /// a request would only fail), and when it has the endpoint. One that has
    /// not reported its features yet is tried anyway; a failure changes nothing.
    var syncsPrefs: Bool {
        controller.isUsable && (controller.profile.lastKnown?.supports(.prefs) ?? true)
    }

    @State private var selectedTab: AppTab = .movies
    @AppStorage(DisplayKeys.startTab) private var startTab = ""
    @AppStorage(DisplayKeys.tabOrder) private var tabOrder = ""
    @AppStorage(DisplayKeys.hiddenTabs) private var hiddenTabs = ""
    @State private var openedOnStartTab = false
    @State private var confirmCenter = ConfirmCenter()
    /// The tab bar, the page's actions and its back button, folding away as
    /// the page scrolls down.
    @State private var chrome = ChromeModel()
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    /// A title opened from iOS search.
    @State private var spotlit: SpotlightTarget?
    /// Quick actions and Siri's "open" requests, taken once the tabs exist.
    @State private var router = LaunchRouter.shared
    @State private var launchAdd = false
    @State private var launchSearch = false
    /// When this build stops opening; nil outside a development install.
    static let expiry = SigningExpiry.current()
    /// Bumped to rebuild a tab's stack, which pops it to its first screen.
    @State private var stackGeneration: [AppTab: Int] = [:]
    /// Tabs with a screen pushed over their first one.
    @State private var pushed: Set<AppTab> = []

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    /// The sidebar on an iPad at regular width, the floating capsule anywhere
    /// else; it follows Split View and Slide Over as their width changes.
    var layout: ShellLayout {
        #if os(iOS)
        ShellLayout(regularWidth: sizeClass == .regular, isPad: UIDevice.current.userInterfaceIdiom == .pad)
        #else
        .tabBar
        #endif
    }

    /// Whether the chrome never folds: VoiceOver should find the tabs and
    /// actions where they always are, and the iPad's sidebar does not fold.
    func pinsChrome(_ layout: ShellLayout) -> Bool {
        voiceOver || layout == .sidebar
    }

    /// A tab tapped in the capsule or the sidebar.
    func tap(_ tab: AppTab) {
        switch TabTap(tab, selected: selectedTab, pushed: pushed) {
        case let .show(tab): withAnimation(.snappy(duration: 0.25)) { selectedTab = tab }
        // as in the PWA and the system tab bar: tapping the tab you are in
        // returns it to its first screen
        case let .popToRoot(tab): stackGeneration[tab, default: 0] += 1
        case .nothing: break
        }
    }

    /// Every tab's stack stays mounted in a ZStack and only the selected one
    /// is visible, so switching tabs keeps scroll position and pushed screens.
    /// Not a TabView: with six tabs UIKit folds the last ones into a "More"
    /// list, and popping a pushed screen in the sixth tab landed there instead
    /// of on the tab's root. Tabs appear only for configured services, so the
    /// bar waits for /services before it knows what to show.
    ///
    /// On a wide iPad the same ZStack sits beside a sidebar instead of over the
    /// capsule. Only the chrome around it changes with the width, never the
    /// stacks' place in the view tree, so moving between Split View sizes keeps
    /// every tab's pushed screens and scroll position, not just the selection.
    var tabs: some View {
        let available = AppTab.arrange(AppTab.available(configured: model.configured),
                                       order: AppTab.list(tabOrder), hidden: Set(AppTab.list(hiddenTabs)))
        let layout = layout
        let expiry = Self.expiry.flatMap { SigningExpiry.isClose($0) ? $0 : nil }
        return Group {
            if !model.servicesKnown {
                ProgressView("Connecting…")
            } else {
                HStack(spacing: 0) {
                    if layout == .sidebar {
                        AppSidebar(title: controller.profile.name, tabs: available, selected: selectedTab,
                                   badges: [.activity: feed.count], tap: tap, expiry: expiry)
                        Divider().ignoresSafeArea()
                    }
                    ZStack {
                        ForEach(available, id: \.self) { tab in
                            // accessibilityHidden has to sit inside the stack:
                            // applied to the NavigationStack itself it is ignored
                            // and the hidden tabs stay visible to VoiceOver.
                            NavigationStack {
                                tabContent(tab)
                                    .accessibilityHidden(tab != selectedTab)
                                    // the first screen leaves view exactly when another is pushed over it;
                                    // switching tabs only changes opacity, so it does not count
                                    .onAppear { pushed.remove(tab) }
                                    .onDisappear { pushed.insert(tab) }
                            }
                            // on the stack, so the screens pushed in it know their tab too
                            .environment(\.chromeTab, tab)
                            .id(stackGeneration[tab, default: 0])
                            .opacity(tab == selectedTab ? 1 : 0)
                            .allowsHitTesting(tab == selectedTab)
                            .zIndex(tab == selectedTab ? 1 : 0)
                        }
                    }
                    // no navigation bar over the pages, so the clock needs its own backing
                    .overlay(alignment: .top) { StatusBarScrim() }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        // no background: the content scrolls on under the floating glass
                        if layout == .tabBar {
                            VStack(spacing: 8) {
                                // faded rather than removed, so the page above does not jump
                                if let expiry { ExpiryStrip(expiry: expiry).opacity(chrome.isExpanded ? 1 : 0) }
                                // the bar switches tabs itself and asks only when the current one is tapped again
                                AppTabBar(tabs: available, selected: $selectedTab, badges: [.activity: feed.count],
                                          collapsed: !chrome.isExpanded, expand: chrome.reset, reselect: tap)
                            }
                            // out of the way while a search field has the keyboard
                            .opacity(chrome.typing ? 0 : 1)
                            .allowsHitTesting(!chrome.typing)
                            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { chrome.barTop = $0 }
                            .onDisappear { chrome.barTop = 0 }
                        }
                    }
                }
                .environment(\.chrome, chrome)
                .onChange(of: selectedTab, initial: true) { _, tab in chrome.select(tab) }
                .onChange(of: pinsChrome(layout), initial: true) { _, pinned in chrome.pinned = pinned }
                .onAppear {
                    // the chosen start tab once per launch; after that the
                    // selection is whatever was tapped last
                    if !openedOnStartTab, let start = AppTab(rawValue: startTab), available.contains(start) {
                        selectedTab = start
                    }
                    openedOnStartTab = true
                    if !available.contains(selectedTab) { selectedTab = AppTab.keeping(selectedTab, in: available) }
                    QuickActions.update(LaunchAction.available(tabs: available, hasArr: model.hasArr))
                    // after the start tab, so a quick action overrides it
                    takeLaunch(available)
                }
                .onChange(of: available) { _, tabs in
                    if !tabs.contains(selectedTab) { selectedTab = AppTab.keeping(selectedTab, in: tabs) }
                    QuickActions.update(LaunchAction.available(tabs: tabs, hasArr: model.hasArr))
                }
                .onChange(of: router.pending) { _, action in
                    if action != nil { takeLaunch(available) }
                }
                .sheet(isPresented: $launchAdd) {
                    AddView(configured: model.configured, api: api, baseURL: controller.activeURL,
                            hasPlex: model.has("plex"), onSessionLost: sessionLost) { launchAdd = false }
                }
                .sheet(isPresented: $launchSearch) {
                    GlobalSearchSheet(api: api, apps: LibraryApp.allCases.filter { model.has($0.rawValue) },
                                      baseURL: controller.activeURL, hasPlex: model.has("plex"),
                                      onSessionLost: sessionLost) { launchSearch = false }
                }
            }
        }
    }

    /// Acts on a waiting quick action or "open" intent. A sheet already up
    /// (a Spotlight title, the connection screen) keeps the screen: stacking
    /// another over it would hide what was just asked for.
    func takeLaunch(_ available: [AppTab]) {
        guard spotlit == nil, !showingConnection, !launchAdd, !launchSearch, let action = router.take() else { return }
        switch action {
        case .activity where available.contains(.activity): selectedTab = .activity
        case .calendar where available.contains(.calendar): selectedTab = .calendar
        case .settings where available.contains(.settings): selectedTab = .settings
        case .add where model.hasArr: launchAdd = true
        case .search where model.hasArr: launchSearch = true
        default: break
        }
    }

    @ViewBuilder func tabContent(_ tab: AppTab) -> some View {
        switch tab {
        case .books:
            LibraryPage(app: .readarr, dashboard: model, api: api, baseURL: controller.activeURL, onSessionLost: sessionLost)
        case .movies:
            LibraryPage(app: .radarr, dashboard: model, api: api, baseURL: controller.activeURL, onSessionLost: sessionLost)
        case .shows:
            LibraryPage(app: .sonarr, dashboard: model, api: api, baseURL: controller.activeURL, onSessionLost: sessionLost)
        case .music:
            LibraryPage(app: .lidarr, dashboard: model, api: api, baseURL: controller.activeURL, onSessionLost: sessionLost)
        case .activity:
            ActivityView(api: api, feed: feed, clients: model.torrentClients, hasArr: model.hasArr,
                         arrs: ArrApp.allCases.filter { model.has($0.rawValue) },
                         baseURL: controller.activeURL, hasPlex: model.has("plex"), onSessionLost: sessionLost)
        case .calendar:
            CalendarScreen(api: api, baseURL: controller.activeURL, shareURL: controller.profile.baseURL,
                           hasPlex: model.has("plex"), onSessionLost: sessionLost)
        case .settings:
            ManageView(
                model: model, api: api, baseURL: controller.activeURL, shareURL: controller.profile.baseURL,
                serverName: controller.profile.name, sessionLabel: sessionLabel,
                backend: controller.profile.lastKnown,
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

struct SpotlightTarget: Identifiable {
    let ref: MediaRef
    var id: String { SpotlightIndexer.identifier(ref) }
}
