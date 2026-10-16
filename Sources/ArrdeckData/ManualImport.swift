import ArrdeckAPI
import Foundation
import Observation
import OpenAPIRuntime

public typealias ImportCandidate = Components.Schemas.ImportCandidateOut
public typealias ImportCommand = Components.Schemas.ImportCommandOut
public typealias ImportOptions = Components.Schemas.ImportOptionsOut
public typealias ImportChoice = Components.Schemas.ImportChoiceOut
public typealias Attention = Components.Schemas.AttentionOut
public typealias ImportFile = Components.Schemas.ManualImportFileIn

/// How the arr gets the files into the library.
public enum ImportMode: String, CaseIterable, Sendable, Hashable {
    /// The arr hardlinks or copies while the client still seeds, and moves
    /// only once the client lets go — the right answer almost always.
    case auto
    case copy
    /// Takes the files away from the torrent client: it stops seeding.
    case move

    public var label: String {
        switch self {
        case .auto: String(localized: "Auto")
        case .copy: String(localized: "Copy")
        case .move: String(localized: "Move")
        }
    }

    public var explanation: String {
        switch self {
        case .auto: String(localized: "Hardlinked or copied, so the torrent keeps seeding.")
        case .copy: String(localized: "Copied; the torrent keeps its files and keeps seeding.")
        case .move: String(localized: "Moved out of the download folder: the torrent loses its files and stops seeding.")
        }
    }
}

/// Where the files to import are: a download an arr is stuck on, or a
/// finished torrent no arr is tracking.
public enum ImportSource: Hashable, Sendable, Identifiable {
    case queue(app: ArrApp, itemID: Int)
    case torrent(app: ArrApp, client: TorrentClient, torrentID: String)

    public var id: String {
        switch self {
        case let .queue(app, itemID): "queue-\(app.rawValue)-\(itemID)"
        case let .torrent(app, client, torrentID): "torrent-\(app.rawValue)-\(client.rawValue)-\(torrentID)"
        }
    }

    public var app: ArrApp {
        switch self {
        case let .queue(app, _), let .torrent(app, _, _): app
        }
    }
}

/// A library entry picked by hand for a file the arr could not place.
public struct ImportTarget: Hashable, Sendable {
    public var movieID: Int?
    public var seriesID: Int?
    public var episodeIDs: [Int] = []
    public var bookID: Int?
    /// Lidarr: the album, and Lidarr works out which track each file is.
    public var albumID: Int?
    public var label: String

    public static func movie(_ id: Int, label: String) -> ImportTarget {
        ImportTarget(movieID: id, label: label)
    }

    public static func episodes(series: Int, ids: [Int], label: String) -> ImportTarget {
        ImportTarget(seriesID: series, episodeIDs: ids, label: label)
    }

    public static func book(_ id: Int, label: String) -> ImportTarget {
        ImportTarget(bookID: id, label: label)
    }

    public static func album(_ id: Int, label: String) -> ImportTarget {
        ImportTarget(albumID: id, label: label)
    }
}

/// A file's quality and languages as the user corrected them. nil is "what
/// the arr detected", so an untouched file sends nothing and the server
/// keeps the arr's own reading.
public struct ImportOverride: Hashable, Sendable {
    public var qualityID: Int?
    public var languageIDs: [Int]?

    public init(qualityID: Int? = nil, languageIDs: [Int]? = nil) {
        self.qualityID = qualityID
        self.languageIDs = languageIDs
    }

    public var isEmpty: Bool { qualityID == nil && languageIDs == nil }
}

/// One import, addressed to the endpoint that fits it.
public enum ImportRequest: Hashable, Sendable {
    /// A stuck download, every file on the arr's own match and detection.
    case plain(ArrApp, Components.Schemas.ManualImportIn)
    /// A stuck download where a file has a hand-picked target or a corrected
    /// quality or language.
    case assign(ArrApp, Components.Schemas.ManualImportAssignIn)
    /// A finished torrent's folder.
    case torrent(ArrApp, Components.Schemas.TorrentImportIn)

    public var app: ArrApp {
        switch self {
        case let .plain(app, _), let .assign(app, _), let .torrent(app, _): app
        }
    }
}

/// Rescuing a stuck download, or importing a finished torrent by hand.
public protocol ManualImportAPI: Sendable {
    /// Queue items the arrs will not import on their own.
    func attention() async throws -> Attention
    /// Everything the arr found, including the files it refused and why.
    func importCandidates(_ source: ImportSource) async throws -> [ImportCandidate]
    /// What a file's quality and languages can be set to (Readarr and
    /// Lidarr: no languages).
    func importOptions(_ app: ArrApp) async throws -> ImportOptions
    /// Starts the arr's ManualImport command.
    func startImport(_ request: ImportRequest) async throws -> ImportCommand
    /// The command as it stands now.
    func importCommand(app: ArrApp, id: Int) async throws -> ImportCommand
}

extension QueueItem {
    /// Why the arr will not import it, in its own words: each status
    /// message's lines (prefixed with its title when that names something
    /// other than the download itself, a single file of a season pack, say),
    /// then the error. Repeats are dropped; the arrs often say it twice.
    public var attentionReasons: [String] {
        var lines: [String] = []
        for group in status_messages ?? [] {
            let title = (group.title ?? "").trimmingCharacters(in: .whitespaces)
            let messages = (group.messages ?? []).filter { !$0.isEmpty }
            if messages.isEmpty {
                if !title.isEmpty { lines.append(title) }
            } else if title.isEmpty || title == self.title {
                lines.append(contentsOf: messages)
            } else {
                lines.append(contentsOf: messages.map { "\(title): \($0)" })
            }
        }
        if let error = error_message, !error.isEmpty { lines.append(error) }
        if lines.isEmpty { lines = (errors ?? []).filter { !$0.isEmpty } }
        var seen = Set<String>()
        return lines.filter { seen.insert($0).inserted }
    }

    /// Queue rows the import sheet can open on: the arr is at the import
    /// step, or stuck there.
    public var importable: Bool {
        guard let state = tracked_state else { return false }
        return state.hasPrefix("import") && state != "imported"
    }
}

/// Which files are picked, where the unplaced ones go, and what quality and
/// languages each is imported as — and the request all that adds up to.
public struct ImportPicks: Hashable, Sendable {
    public var picked: Set<String> = []
    public var targets: [String: ImportTarget] = [:]
    public var overrides: [String: ImportOverride] = [:]
    public var mode: ImportMode = .auto

    public init() {}

    /// A file can go when the arr placed it or the user did, and the arr
    /// read a quality from it or the user set one: the arr refuses a file
    /// without either.
    public func ready(_ candidate: ImportCandidate) -> Bool {
        let placed = candidate.importable == true || targets[candidate.path] != nil
        let quality = candidate.quality_id != nil || overrides[candidate.path]?.qualityID != nil
        return placed && quality
    }

    /// Picks or unpicks a ready file; a file that is not ready stays out.
    /// Returns whether the file is picked afterwards.
    @discardableResult
    public mutating func toggle(_ candidate: ImportCandidate) -> Bool {
        if picked.remove(candidate.path) != nil { return false }
        guard ready(candidate) else { return false }
        picked.insert(candidate.path)
        return true
    }

    /// Every ready file, or none when every ready file already is.
    public mutating func toggleAll(_ candidates: [ImportCandidate]) {
        let ready = Set(candidates.filter(ready).map(\.path))
        picked = !ready.isEmpty && ready.isSubset(of: picked) ? [] : ready
    }

    public func allPicked(_ candidates: [ImportCandidate]) -> Bool {
        let ready = candidates.filter(ready).map(\.path)
        return !ready.isEmpty && ready.allSatisfy(picked.contains)
    }

    /// Choosing where a file goes is choosing to import it.
    public mutating func assign(_ target: ImportTarget, to candidate: ImportCandidate) {
        targets[candidate.path] = target
        if ready(candidate) { picked.insert(candidate.path) }
    }

    /// The same, except that an album arrives as many files: an album picked
    /// for one goes to every file the arr could not place and nobody has
    /// pointed anywhere yet, so a whole folder takes one pick. Files the arr
    /// placed, and files already given a target, are left alone.
    public mutating func assign(_ target: ImportTarget, to candidate: ImportCandidate, among candidates: [ImportCandidate]) {
        assign(target, to: candidate)
        guard target.albumID != nil else { return }
        for other in candidates where other.path != candidate.path && other.importable != true && targets[other.path] == nil {
            assign(target, to: other)
        }
    }

    /// Back to the arr's own match, which for a file it could not place is
    /// none: such a file drops out of the pick.
    public mutating func clearTarget(_ candidate: ImportCandidate) {
        targets[candidate.path] = nil
        if !ready(candidate) { picked.remove(candidate.path) }
    }

    // MARK: Quality and languages

    public func qualityID(_ candidate: ImportCandidate) -> Int? {
        overrides[candidate.path]?.qualityID ?? candidate.quality_id
    }

    public func languageIDs(_ candidate: ImportCandidate) -> [Int] {
        overrides[candidate.path]?.languageIDs ?? candidate.language_ids ?? []
    }

    /// Picking what the arr detected is not an override.
    public mutating func setQuality(_ id: Int, for candidate: ImportCandidate) {
        var override = overrides[candidate.path] ?? ImportOverride()
        override.qualityID = id == candidate.quality_id ? nil : id
        store(override, for: candidate)
    }

    /// An empty pick, or the detected set again, means "keep what the arr
    /// detected" — never "no language".
    public mutating func toggleLanguage(_ id: Int, for candidate: ImportCandidate) {
        var ids = languageIDs(candidate)
        if let index = ids.firstIndex(of: id) { ids.remove(at: index) } else { ids.append(id) }
        var override = overrides[candidate.path] ?? ImportOverride()
        let detected = Set(candidate.language_ids ?? [])
        override.languageIDs = ids.isEmpty || Set(ids) == detected ? nil : ids
        store(override, for: candidate)
    }

    public mutating func resetOverride(_ candidate: ImportCandidate) {
        overrides[candidate.path] = nil
    }

    public func isOverridden(_ candidate: ImportCandidate) -> Bool {
        !(overrides[candidate.path]?.isEmpty ?? true)
    }

    private mutating func store(_ override: ImportOverride, for candidate: ImportCandidate) {
        overrides[candidate.path] = override.isEmpty ? nil : override
    }

    // MARK: The request

    /// The picked files that can go, in the order the arr listed them.
    public func chosen(_ candidates: [ImportCandidate]) -> [ImportCandidate] {
        candidates.filter { picked.contains($0.path) && ready($0) }
    }

    /// nil when nothing is picked. A stuck download goes to the plain
    /// endpoint while every file rides on the arr's own match and detection,
    /// and to assign as soon as one has a target or an override; a torrent
    /// always goes to its own endpoint, which takes both.
    public func request(for source: ImportSource, candidates: [ImportCandidate]) -> ImportRequest? {
        let files = chosen(candidates)
        guard !files.isEmpty else { return nil }
        switch source {
        case let .queue(app, itemID):
            let custom = files.contains { targets[$0.path] != nil || isOverridden($0) }
            if !custom {
                return .plain(app, .init(item_id: itemID, mode: .init(rawValue: mode.rawValue), paths: files.map(\.path)))
            }
            return .assign(app, .init(files: files.map(file), item_id: itemID, mode: .init(rawValue: mode.rawValue)))
        case let .torrent(app, client, torrentID):
            return .torrent(app, .init(
                client: client == .qbittorrent ? .qbittorrent : .transmission,
                files: files.map(file), mode: .init(rawValue: mode.rawValue), torrent_id: torrentID
            ))
        }
    }

    /// One file for assign or torrent: only what the user chose is sent,
    /// and the server fills in the arr's own answer for the rest.
    func file(_ candidate: ImportCandidate) -> ImportFile {
        let target = targets[candidate.path]
        let override = overrides[candidate.path]
        return ImportFile(
            album_id: target?.albumID,
            book_id: target?.bookID,
            episode_ids: target.flatMap { $0.episodeIDs.isEmpty ? nil : $0.episodeIDs },
            language_ids: override?.languageIDs,
            movie_id: target?.movieID,
            path: candidate.path,
            quality_id: override?.qualityID,
            series_id: target?.seriesID
        )
    }
}

/// Where an import stands, for the line under the button.
public enum ImportOutcome: Equatable, Sendable {
    /// The arr's running commentary, when it gives one.
    case running(String?)
    case succeeded(String)
    case failed(String)
}

/// The import sheet: what the arr found, the user's picks, and the command
/// followed until the arr says it is done.
@MainActor @Observable
public final class ImportModel {
    public let source: ImportSource
    public private(set) var candidates: Loadable<[ImportCandidate]> = .loading
    /// nil until loaded; the sheet still works on the arr's detection without.
    public private(set) var options: ImportOptions?
    public var picks = ImportPicks()
    public private(set) var command: ImportCommand?
    public private(set) var starting = false
    public var actionError: String?

    private let api: any ManualImportAPI
    private let pollInterval: Duration
    private let maxPolls: Int

    public init(
        source: ImportSource, api: any ManualImportAPI,
        pollInterval: Duration = .seconds(1), maxPolls: Int = 600
    ) {
        self.source = source
        self.api = api
        self.pollInterval = pollInterval
        self.maxPolls = maxPolls
    }

    public var app: ArrApp { source.app }
    public var list: [ImportCandidate] { candidates.value ?? [] }

    /// Lidarr's files are tracks of one album, so one album pick goes to
    /// every unplaced file; the sheet says so when there is more than one.
    public var albumForAll: Bool { app == .lidarr && list.filter { $0.importable != true }.count > 1 }

    /// Points a file at a library entry; an album goes to every file still
    /// without one.
    public func assign(_ target: ImportTarget, to candidate: ImportCandidate) {
        picks.assign(target, to: candidate, among: list)
    }
    public var request: ImportRequest? { picks.request(for: source, candidates: list) }
    public var chosenCount: Int { picks.chosen(list).count }
    /// One import per sheet: the files it took are gone from the folder.
    public var started: Bool { command != nil || starting }
    public var finished: Bool { command?.done == true }

    public func load() async {
        async let found: Void = loadCandidates()
        async let choices: Void = loadOptions()
        _ = await (found, choices)
    }

    private func loadCandidates() async {
        do {
            candidates = .loaded(try await api.importCandidates(source))
        } catch {
            candidates = .failed(describe(error))
        }
    }

    private func loadOptions() async {
        options = try? await api.importOptions(app)
    }

    public func qualityName(_ candidate: ImportCandidate) -> String? {
        guard let override = picks.overrides[candidate.path]?.qualityID else { return candidate.quality }
        return options?.qualities?.first { $0.id == override }?.name ?? candidate.quality
    }

    public func languageNames(_ candidate: ImportCandidate) -> [String] {
        guard let override = picks.overrides[candidate.path]?.languageIDs else { return candidate.languages ?? [] }
        return override.map { id in options?.languages?.first { $0.id == id }?.name ?? "#\(id)" }
    }

    /// Starts the import and follows it until the arr says it is done.
    public func start() async {
        guard !started, let request else { return }
        starting = true
        actionError = nil
        do {
            command = try await api.startImport(request)
            // the command is what holds the sheet now; the list stays readable
            starting = false
        } catch {
            starting = false
            actionError = describe(error)
            return
        }
        await follow()
    }

    /// Polls until done; a few failed polls in a row (the arr restarting,
    /// say) end the wait without claiming the import failed.
    func follow() async {
        var failures = 0
        var polls = 0
        while let current = command, current.done != true, polls < maxPolls, !Task.isCancelled {
            try? await Task.sleep(for: pollInterval)
            polls += 1
            do {
                command = try await api.importCommand(app: app, id: current.id)
                failures = 0
            } catch {
                failures += 1
                if failures >= 3 {
                    actionError = describe(error)
                    return
                }
            }
        }
    }

    public var outcome: ImportOutcome? {
        guard let command else { return nil }
        let name = Services.label(app.rawValue)
        guard command.done == true else { return .running(command.message) }
        guard command.ok == true else {
            return .failed(command.message ?? String(localized: "\(name) could not import the files"))
        }
        // `imported` is the arr's own count of files it processed; it can
        // still have turned some down, so this says processed, not imported.
        if let count = command.imported {
            return .succeeded(count == 1
                ? String(localized: "\(name) processed 1 file")
                : String(localized: "\(name) processed \(count) files"))
        }
        return .succeeded(command.message ?? String(localized: "\(name) finished the import"))
    }

    private func describe(_ error: any Error) -> String {
        (error as? APIError)?.description ?? error.localizedDescription
    }
}

/// The library rows the target picker offers, filtered by what was typed.
public enum ImportTargetSearch {
    public static let limit = 60

    static func matches(_ query: String, _ fields: String?...) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return true }
        return fields.contains { $0?.localizedCaseInsensitiveContains(needle) == true }
    }

    public static func movies(_ movies: [LibraryMovie], query: String) -> [LibraryMovie] {
        Array(movies.filter { matches(query, $0.title) }
            .sorted { ($0.title ?? "").localizedCaseInsensitiveCompare($1.title ?? "") == .orderedAscending }
            .prefix(limit))
    }

    public static func series(_ series: [LibrarySeries], query: String) -> [LibrarySeries] {
        Array(series.filter { matches(query, $0.title) }
            .sorted { ($0.title ?? "").localizedCaseInsensitiveCompare($1.title ?? "") == .orderedAscending }
            .prefix(limit))
    }

    /// An author's name finds their books too: that is how a shelf is browsed.
    public static func books(_ books: [LibraryBook], query: String) -> [LibraryBook] {
        Array(books.filter { matches(query, $0.title, $0.author) }
            .sorted { ($0.title ?? "").localizedCaseInsensitiveCompare($1.title ?? "") == .orderedAscending }
            .prefix(limit))
    }

    /// "Show S01E02", or "Show S01E02–E04" for a file holding several.
    public static func episodeLabel(series: String, season: Int, episodes: [Int]) -> String {
        let sorted = episodes.sorted()
        guard let first = sorted.first else { return series }
        var label = String(format: "%@ S%02dE%02d", series, season, first)
        if let last = sorted.last, last != first { label += String(format: "–E%02d", last) }
        return label
    }
}
