import Foundation
import Observation

/// Search every library at once. The rows are the libraries' own, fetched
/// once when the search opens; typing costs no request.
public enum GlobalSearch {
    public struct Hit: Identifiable, Hashable, Sendable {
        public enum Group: Int, CaseIterable, Sendable { case movies, shows, books, authors }
        public var id: String
        public var group: Group
        public var title: String
        public var subtitle: String?
        public var poster: String?
        /// nil for an author, who opens by `authorID`
        public var ref: MediaRef?
        public var authorID: Int?
    }

    static let perGroup = 6

    /// Exact match first, then prefix, then a word starting with it, then the rest.
    static func rank(_ title: String, _ needle: String) -> Int {
        let t = title.lowercased()
        if t == needle { return 0 }
        if t.hasPrefix(needle) { return 1 }
        if t.split(separator: " ").contains(where: { $0.hasPrefix(needle) }) { return 2 }
        return 3
    }

    public static func hits(_ rows: [LibraryRow], authors: [(id: Int, name: String)], query: String) -> [Hit] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard needle.count >= 2 else { return [] }
        func top(_ list: [Hit]) -> [Hit] {
            Array(list.sorted { rank($0.title, needle) < rank($1.title, needle) }.prefix(perGroup))
        }
        func group(of row: LibraryRow) -> Hit.Group {
            switch row.ref {
            case .movie: .movies
            case .series: .shows
            case .book: .books
            }
        }
        let titled = rows.filter { $0.title.lowercased().contains(needle) || ($0.seriesTitle ?? "").lowercased().contains(needle) }
            .map { row in
                Hit(id: "\(row.ref)", group: group(of: row), title: row.title,
                    subtitle: row.author ?? row.year.map(String.init), poster: row.poster, ref: row.ref)
            }
        let people = authors.filter { $0.name.lowercased().contains(needle) }
            .map { Hit(id: "author:\($0.id)", group: .authors, title: $0.name, authorID: $0.id) }
        return Hit.Group.allCases.flatMap { g in top((g == .authors ? people : titled).filter { $0.group == g }) }
    }
}

@MainActor @Observable
public final class GlobalSearchModel {
    public var query = ""
    public private(set) var rows: [LibraryRow] = []
    public private(set) var authors: [(id: Int, name: String)] = []
    public private(set) var loaded = false
    private let api: any ManageAPI
    private let apps: [ArrApp]

    public init(api: any ManageAPI, apps: [ArrApp]) {
        self.api = api
        self.apps = apps
    }

    public var hits: [GlobalSearch.Hit] { GlobalSearch.hits(rows, authors: authors, query: query) }

    public func load() async {
        guard !loaded else { return }
        var all: [LibraryRow] = []
        var books: [LibraryBook] = []
        for app in apps {
            switch app {
            case .radarr: all += ((try? await api.libraryMovies()) ?? []).map(LibraryRow.init)
            case .sonarr: all += ((try? await api.librarySeries()) ?? []).map(LibraryRow.init)
            case .readarr:
                books = (try? await api.libraryBooks()) ?? []
                all += books.map(LibraryRow.init)
            }
        }
        var seen = Set<Int>()
        authors = books.compactMap { b in
            guard let id = b.author_id, let name = b.author, seen.insert(id).inserted else { return nil }
            return (id, name)
        }
        rows = all
        loaded = true
    }
}
