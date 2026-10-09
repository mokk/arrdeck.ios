import AppIntents
import ArrdeckData
import ArrdeckKit
import ArrdeckUI

/// Siri and the Shortcuts app. Thin on purpose: the sentences are built and
/// tested in ArrdeckData (SpokenSummary); this only finds the server and asks.
/// The server is the one last opened, or the only one saved.
enum IntentServer {
    static func api() -> LiveAPI? {
        guard let profiles = try? KeychainProfileStore().load(),
              let profile = LastProfile.pick(from: profiles)
        else { return nil }
        return LiveAPI(baseURL: profile.baseURL)
    }

    static func answer(_ ask: (LiveAPI) async throws -> String) async -> String {
        guard let api = api() else { return SpokenSummary.noServer }
        do {
            return try await ask(api)
        } catch {
            return SpokenSummary.failure(error)
        }
    }
}

struct WhatsDownloadingIntent: AppIntent {
    static let title: LocalizedStringResource = "What's downloading"
    static let description = IntentDescription("Says what arrdeck is downloading right now.")
    // what you download is not for whoever picks up a locked phone
    static let authenticationPolicy = IntentAuthenticationPolicy.requiresAuthentication

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let said = await IntentServer.answer { try await SpokenSummary.downloading(api: $0) }
        return .result(dialog: "\(said)")
    }
}

struct WhatsOnTodayIntent: AppIntent {
    static let title: LocalizedStringResource = "What's on today"
    static let description = IntentDescription("Says which episodes, films and books come out today.")
    static let authenticationPolicy = IntentAuthenticationPolicy.requiresAuthentication

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let said = await IntentServer.answer { try await SpokenSummary.today(api: $0) }
        return .result(dialog: "\(said)")
    }
}

enum ArrdeckScreen: String, AppEnum {
    case activity, calendar, add, search

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Screen"
    static let caseDisplayRepresentations: [ArrdeckScreen: DisplayRepresentation] = [
        .activity: "Activity",
        .calendar: "Calendar",
        .add: "Add",
        .search: "Search",
    ]
}

struct OpenScreenIntent: AppIntent {
    static let title: LocalizedStringResource = "Open in arrdeck"
    static let description = IntentDescription("Opens arrdeck on Activity, Calendar, Add or Search.")
    static let openAppWhenRun = true

    @Parameter(title: "Screen") var screen: ArrdeckScreen

    @MainActor
    func perform() async throws -> some IntentResult {
        if let action = LaunchAction(rawValue: screen.rawValue) { LaunchRouter.shared.open(action) }
        return .result()
    }
}

struct ArrdeckShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: WhatsDownloadingIntent(),
            phrases: ["What's downloading in \(.applicationName)", "\(.applicationName) downloads"],
            shortTitle: "Downloading", systemImageName: "arrow.down.circle"
        )
        AppShortcut(
            intent: WhatsOnTodayIntent(),
            phrases: ["What's on today in \(.applicationName)", "\(.applicationName) today"],
            shortTitle: "Today", systemImageName: "calendar"
        )
        AppShortcut(
            intent: OpenScreenIntent(),
            phrases: ["Open \(\.$screen) in \(.applicationName)", "Show \(.applicationName) \(\.$screen)"],
            shortTitle: "Open", systemImageName: "arrow.up.forward.app"
        )
    }
}
