import ArrdeckAPI
import Foundation
import Observation

public typealias Restartable = Components.Schemas.RestartableOut
public typealias RestartableProject = Components.Schemas.RestartableProjectOut

/// `docker compose restart` for a running project, `up -d` for a stopped one.
public enum ServiceAction: String, Sendable {
    case restart, up
}

/// Why a restart did not happen, in the terms the Services section shows.
public enum ServiceActionError: Error, Equatable, Sendable, CustomStringConvertible {
    /// 409: no helper configured in Connections.
    case notConfigured
    /// 502: configured, but nothing answered.
    case unreachable(String?)
    /// 429: the helper refuses a second restart of the same project this soon.
    case tooSoon(retryAfter: Int?)
    case failed(Int, String?)

    public var description: String {
        switch self {
        case .notConfigured:
            String(localized: "The host helper is not set up.")
        case let .unreachable(message):
            message.map { String(localized: "The host helper could not be reached: \($0)") }
                ?? String(localized: "The host helper could not be reached.")
        case let .tooSoon(seconds):
            seconds.map { String(localized: "It was restarted a moment ago. Try again in \($0) s.") }
                ?? String(localized: "It was restarted a moment ago. Try again shortly.")
        case let .failed(code, message):
            message ?? "HTTP \(code)"
        }
    }
}

/// The compose projects the host helper may restart, and the restart itself.
public protocol ServiceControlAPI: Sendable {
    /// Never fails for "not configured" or "unreachable": those are states.
    func restartable() async throws -> Restartable
    /// True when the answer is only "on its way": restarting arrdeck itself
    /// ends this process before the helper could reply.
    func serviceAction(_ project: String, _ action: ServiceAction) async throws -> Bool
}

extension LiveAPI: ServiceControlAPI {
    public func restartable() async throws -> Restartable {
        try await call {
            switch try await client.restartable_api_v1_system_restartable_get() {
            case let .ok(ok): try ok.body.json
            case let .undocumented(code, _): throw APIError.status(code)
            }
        }
    }

    public func serviceAction(_ project: String, _ action: ServiceAction) async throws -> Bool {
        // The switch sits outside `call`, which would turn these errors into
        // transport failures and lose what the helper said.
        let output = try await call {
            try await client.service_action_api_v1_system_services__name___action__post(
                path: .init(name: project, action: action == .restart ? .restart : .up)
            )
        }
        switch output {
        case let .ok(ok): return try await call { try ok.body.json.pending ?? false }
        case .unprocessableContent: throw APIError.unexpectedStatus(422)
        case let .undocumented(code, payload):
            switch code {
            case 401: throw APIError.unauthorized
            case 409: throw ServiceActionError.notConfigured
            case 429: throw ServiceActionError.tooSoon(retryAfter: ServerMessage.retryAfter(payload))
            case 502: throw ServiceActionError.unreachable(await ServerMessage.read(payload))
            default: throw ServiceActionError.failed(code, await ServerMessage.read(payload))
            }
        }
    }
}

extension ServiceStatus {
    /// "down 14m" while the backend's watcher has it down; nil while it answers.
    public func downFor(now: Date = .now) -> String? {
        guard let since = down_since else { return nil }
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        return String(localized: "down \(Format.eta(seconds))")
    }
}

extension RestartableProject {
    /// What its button does: a stopped project is started, not restarted.
    public var action: ServiceAction { running == true ? .restart : .up }
    public var isSelf: Bool { is_self == true }

    public var label: String { service.map(Services.label) ?? name }
}

/// Settings → System's restart buttons: whether the host helper is there,
/// what it lists, and the outcome of the last restart.
@MainActor @Observable
public final class ServiceControlModel {
    public enum Helper: Equatable, Sendable {
        case loading
        /// No helper in Connections: the buttons are replaced by a note.
        case notConfigured
        case unreachable(String)
        case ready([RestartableProject])
        case failed(String)
    }

    public private(set) var helper: Helper = .loading
    /// Projects with a restart or start in flight.
    public private(set) var working: Set<String> = []
    /// "Radarr restarted", or that arrdeck is on its way back.
    public private(set) var note: String?
    public var error: String?
    private let api: any ServiceControlAPI
    private let onSessionLost: @MainActor () -> Void

    public init(api: any ServiceControlAPI, onSessionLost: @escaping @MainActor () -> Void = {}) {
        self.api = api
        self.onSessionLost = onSessionLost
    }

    public var projects: [RestartableProject] {
        if case let .ready(list) = helper { return list }
        return []
    }

    /// The project behind a status row, matched by the service name the
    /// backend gives it.
    public func project(for service: String) -> RestartableProject? {
        projects.first { $0.service == service }
    }

    /// Projects no status row stands for — arrdeck itself, or a stack named
    /// differently from its service — listed after the services.
    public func unmatched(services: Set<String>) -> [RestartableProject] {
        projects.filter { project in project.service.map { !services.contains($0) } ?? true }
    }

    public func load() async {
        do {
            let answer = try await api.restartable()
            if answer.configured != true {
                helper = .notConfigured
            } else if let error = answer.error {
                helper = .unreachable(error)
            } else {
                helper = .ready(answer.projects ?? [])
            }
        } catch {
            if case .some(.unauthorized) = error as? APIError { onSessionLost(); return }
            if case .loading = helper { helper = .failed((error as? APIError)?.description ?? error.localizedDescription) }
        }
    }

    /// Restarts or starts it, by what it is doing now. Returns whether the
    /// helper took it, so the caller can refresh the status list.
    @discardableResult
    public func act(_ project: RestartableProject) async -> Bool {
        let action = project.action
        working.insert(project.name)
        defer { working.remove(project.name) }
        note = nil
        do {
            let pending = try await api.serviceAction(project.name, action)
            if pending || project.isSelf {
                note = String(localized: "arrdeck is restarting — back in a moment")
                // nothing to reload: the server that would answer is going away
                return true
            }
            note = action == .restart
                ? String(localized: "\(project.label) restarted")
                : String(localized: "\(project.label) started")
            await load()
            return true
        } catch {
            if case .some(.unauthorized) = error as? APIError { onSessionLost(); return false }
            if case .some(.notConfigured) = error as? ServiceActionError { helper = .notConfigured }
            self.error = (error as? ServiceActionError)?.description
                ?? (error as? APIError)?.description ?? error.localizedDescription
            return false
        }
    }
}
