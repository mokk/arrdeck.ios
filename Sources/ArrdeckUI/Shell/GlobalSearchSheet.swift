import ArrdeckData
import SwiftUI
#if canImport(CoreSpotlight)
@preconcurrency import CoreSpotlight
#endif

/// Search every library at once, from the magnifier on the library tabs.
struct GlobalSearchSheet: View {
    @State private var model: GlobalSearchModel
    let api: any LibraryPageAPI
    let baseURL: URL
    let hasPlex: Bool
    let onSessionLost: @MainActor () -> Void
    let dismiss: () -> Void

    init(api: any LibraryPageAPI, apps: [ArrApp], baseURL: URL, hasPlex: Bool,
         onSessionLost: @escaping @MainActor () -> Void, dismiss: @escaping () -> Void) {
        _model = State(initialValue: GlobalSearchModel(api: api, apps: apps))
        self.api = api
        self.baseURL = baseURL
        self.hasPlex = hasPlex
        self.onSessionLost = onSessionLost
        self.dismiss = dismiss
    }

    func label(_ group: GlobalSearch.Hit.Group) -> String {
        switch group {
        case .movies: String(localized: "Movies")
        case .shows: String(localized: "Shows")
        case .books: String(localized: "Books")
        case .authors: String(localized: "Authors")
        }
    }

    var body: some View {
        NavigationStack {
            List {
                let hits = model.hits
                if !model.loaded {
                    LoadingRow()
                } else if model.query.trimmingCharacters(in: .whitespaces).count >= 2, hits.isEmpty {
                    EmptyNote("Nothing in your libraries matches.")
                }
                ForEach(GlobalSearch.Hit.Group.allCases, id: \.self) { group in
                    let inGroup = hits.filter { $0.group == group }
                    if !inGroup.isEmpty {
                        Section(label(group)) {
                            ForEach(inGroup) { hit in
                                if let ref = hit.ref {
                                    NavigationLink(value: ref) { row(hit) }
                                } else if let author = hit.authorID {
                                    NavigationLink(value: AuthorRef(author)) { row(hit) }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Search everything")
            .searchable(text: $model.query, placement: .alwaysVisible, prompt: Text("Films, shows, books, authors"))
            .navigationDestination(for: MediaRef.self) { ref in
                MediaDestination(ref: ref, api: api, baseURL: baseURL, hasPlex: hasPlex, onSessionLost: onSessionLost)
            }
            .navigationDestination(for: AuthorRef.self) { ref in
                AuthorDetailView(id: ref.id, api: api, baseURL: baseURL, onSessionLost: onSessionLost)
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done", action: dismiss) } }
            .task { await model.load() }
        }
    }

    func row(_ hit: GlobalSearch.Hit) -> some View {
        HStack(spacing: 10) {
            Poster(path: hit.poster, baseURL: baseURL, width: 30, cornerRadius: 4, title: hit.title)
            VStack(alignment: .leading, spacing: 1) {
                Text(hit.title).font(.subheadline.weight(.medium)).lineLimit(1)
                if let subtitle = hit.subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
    }
}

/// An author as a navigation value.
struct AuthorRef: Hashable {
    let id: Int
    init(_ id: Int) { self.id = id }
}

/// Puts the library's titles into iOS search, so a film or book can be found
/// from the home screen and opens here.
enum SpotlightIndexer {
    static func domain(_ app: ArrApp) -> String { "arrdeck.library.\(app.rawValue)" }

    static func identifier(_ ref: MediaRef) -> String {
        switch ref {
        case let .movie(id): "movie:\(id)"
        case let .series(id): "series:\(id)"
        case let .book(id): "book:\(id)"
        }
    }

    static func ref(from identifier: String) -> MediaRef? {
        let parts = identifier.split(separator: ":")
        guard parts.count == 2, let id = Int(parts[1]) else { return nil }
        return switch parts[0] {
        case "movie": .movie(id)
        case "series": .series(id)
        case "book": .book(id)
        default: nil
        }
    }

    /// Replaces one library's entries with the rows just loaded.
    static func index(_ rows: [LibraryRow], app: ArrApp) {
        #if canImport(CoreSpotlight)
        let items = rows.map { row in
            let attributes = CSSearchableItemAttributeSet(contentType: .content)
            attributes.title = row.title
            attributes.contentDescription = [row.author, row.year.map(String.init)].compactMap { $0 }.joined(separator: " · ")
            return CSSearchableItem(uniqueIdentifier: identifier(row.ref), domainIdentifier: domain(app), attributeSet: attributes)
        }
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: [domain(app)]) { _ in
            index.indexSearchableItems(items) { _ in }
        }
        #endif
    }
}

#if canImport(CoreSpotlight)
let spotlightActivity = CSSearchableItemActionType
let spotlightIdentifierKey = CSSearchableItemActivityIdentifier
#else
let spotlightActivity = "com.apple.corespotlightitem"
let spotlightIdentifierKey = "kCSSearchableItemActivityIdentifier"
#endif
