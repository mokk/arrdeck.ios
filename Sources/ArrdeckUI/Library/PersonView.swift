import ArrdeckData
import SwiftUI

/// Someone from a film's credits: their films in the library first, then the
/// released ones that are not, ready to add.
struct PersonView: View {
    let ref: PersonRef
    let api: any PeopleAPI
    let adder: (any DiscoverAPI & LibraryAPI)?
    let baseURL: URL
    @State private var person: Loadable<Person> = .loading
    @State private var adding: SearchResult?

    let columns = [GridItem(.adaptive(minimum: 100, maximum: 110), spacing: 14, alignment: .top)]

    var body: some View {
        ScrollView {
            switch person {
            case .loading: LoadingRow().padding()
            case let .failed(reason): ErrorNote(reason).padding()
            case let .loaded(person):
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 14) {
                        if let image = person.image, let url = URL(string: image, relativeTo: baseURL) {
                            AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Circle().fill(.quaternary) }
                                .frame(width: 72, height: 72).clipShape(Circle())
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            if let known = person.known_for { Text(known).font(.subheadline).foregroundStyle(.secondary) }
                            Text("\(person.owned?.count ?? 0) films in your library").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Text("In your library").font(.headline)
                    if (person.owned ?? []).isEmpty {
                        EmptyNote("None of their films are in the library yet.")
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                            ForEach(person.owned ?? [], id: \.movie_id) { movie in
                                NavigationLink(value: MediaRef.movie(movie.movie_id)) {
                                    tile(title: movie.title ?? "", poster: movie.poster,
                                         caption: [movie.year.map(String.init), movie.role].compactMap { $0 }.joined(separator: " · "))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if !(person.elsewhere ?? []).isEmpty {
                        Text("Not in your library").font(.headline)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                            ForEach(person.elsewhere ?? [], id: \.remote_id) { result in
                                Button { adding = result } label: {
                                    tile(title: result.title, poster: result.poster, caption: result.year.map(String.init) ?? "")
                                }
                                .buttonStyle(.plain)
                                .disabled(adder == nil)
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .background(Color.grouped)
        .navigationTitle(person.value?.name ?? "")
        .task {
            do { person = .loaded(try await api.person(ref.tmdbID)) } catch { person = .failed(error.localizedDescription) }
        }
        .sheet(item: $adding) { result in
            if let adder { MediaSheet(result: result, api: adder, baseURL: baseURL) { adding = nil } }
        }
    }

    func tile(title: String, poster: String?, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Poster(path: poster, baseURL: baseURL, width: 100, cornerRadius: 10, title: title)
            Text(title).font(.caption.weight(.semibold)).lineLimit(2)
            Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 100, alignment: .leading)
    }
}

/// The wide fanart above a title's page; a book passes its cover, blurred.
struct Backdrop: View {
    let path: String
    let baseURL: URL
    var blurred = false

    var body: some View {
        AsyncImage(url: URL(string: path, relativeTo: baseURL)) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
                    .blur(radius: blurred ? 30 : 0)
                    .saturation(blurred ? 1.4 : 1)
            } else {
                Color.clear
            }
        }
        .frame(height: 180)
        .frame(maxWidth: .infinity)
        .clipped()
        .overlay(LinearGradient(colors: [.clear, Color.grouped], startPoint: .center, endPoint: .bottom))
        .accessibilityHidden(true)
    }
}

/// The backdrop as a list's first, edge-to-edge section.
struct BackdropSection: View {
    let path: String?
    let baseURL: URL
    var blurred = false

    var body: some View {
        if let path {
            Section {
                Backdrop(path: path, baseURL: baseURL, blurred: blurred)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
        }
    }
}
