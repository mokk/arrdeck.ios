import ArrdeckAPI
import ArrdeckData
import Foundation
import Testing

@Suite struct RatingsTests {
    @Test func aMovieDetailDecodesEverySourceIncludingNullVotes() async throws {
        let body = """
        {"id": 182, "title": "50 First Dates", "ratings": [
          {"source": "imdb", "value": 6.8, "votes": 420894},
          {"source": "rottenTomatoes", "value": 45.0, "votes": null},
          {"source": "trakt", "value": 7.13652, "votes": 11603}]}
        """
        let api = LiveAPI(client: Client(
            serverURL: URL(string: "http://stub")!,
            transport: StubTransport(routes: ["/api/v1/library/movies/182/detail": .init(body: body)])
        ))
        let ratings = try await api.movieDetail(182).ratings ?? []
        #expect(ratings.map(\.source) == ["imdb", "rottenTomatoes", "trakt"])
        #expect(ratings[1].votes == nil)
        #expect(ratings.map { Format.rating($0, locale: Locale(identifier: "en_US")).display } == ["IMDb 6.8", "RT 45%", "Trakt 7.1"])
    }

    let english = Locale(identifier: "en_US")

    func chip(_ source: String, _ value: Double, votes: Int? = nil, locale: Locale? = nil) -> RatingChip {
        Format.rating(Rating(source: source, value: value, votes: votes), locale: locale ?? english)
    }

    @Test func eachSourceIsWrittenTheWayItsSiteDoes() {
        #expect(chip("imdb", 7.1).text == "7.1")
        #expect(chip("imdb", 8).text == "8.0")
        #expect(chip("tmdb", 6.901).text == "6.9")
        #expect(chip("trakt", 6.85406).text == "6.9")
        #expect(chip("rottenTomatoes", 89).text == "89%")
        #expect(chip("rottenTomatoes", 81.6).text == "82%")
        #expect(chip("metacritic", 64).text == "64")
        #expect(chip("metacritic", 63.5).text == "64")
    }

    @Test func chipsReadAsLabelThenScore() {
        #expect(chip("imdb", 7.1).display == "IMDb 7.1")
        #expect(chip("tmdb", 6.4).display == "TMDB 6.4")
        #expect(chip("rottenTomatoes", 82).display == "RT 82%")
        #expect(chip("metacritic", 64).display == "Metacritic 64")
        #expect(chip("trakt", 5.8).display == "Trakt 5.8")
    }

    @Test func rottenTomatoesIsLabelledCompactlyWithItsFullNameForVoiceOver() {
        let rt = chip("rottenTomatoes", 82)
        #expect(rt.label == "RT")
        #expect(rt.name == "Rotten Tomatoes")
        #expect(chip("imdb", 7).label == "IMDb")
    }

    @Test func aSourceItDoesNotKnowKeepsItsOwnName() {
        let other = chip("letterboxd", 3.8)
        #expect(other.label == "letterboxd")
        #expect(other.text == "3.8")
    }

    @Test func decimalsFollowTheLocaleAndVotesDoNotChangeTheText() {
        #expect(chip("imdb", 7.1, locale: Locale(identifier: "da_DK")).text == "7,1")
        #expect(chip("imdb", 7.1, votes: 420_894).text == "7.1")
    }
}
