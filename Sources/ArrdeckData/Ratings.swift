import ArrdeckAPI
import Foundation

public typealias Rating = Components.Schemas.RatingOut

/// One source's score as it is shown: the way that source writes it.
public struct RatingChip: Equatable, Sendable {
    /// "IMDb", "RT" — short enough for a row of chips.
    public let label: String
    /// "Rotten Tomatoes" — what VoiceOver says.
    public let name: String
    /// "7.1", "82%", "64"
    public let text: String

    public var display: String { "\(label) \(text)" }
}

extension Format {
    /// The arrs send Rotten Tomatoes and Metacritic as 0–100 and the rest out
    /// of 10, so each is written the way its own site does: "82%", "64", "7.1".
    /// A source nobody here has heard of keeps its own name.
    public static func rating(_ rating: Rating, locale: Locale = .current) -> RatingChip {
        let names: (label: String, name: String) = switch rating.source {
        case "imdb": ("IMDb", "IMDb")
        case "tmdb": ("TMDB", "TMDB")
        case "rottenTomatoes": ("RT", "Rotten Tomatoes")
        case "metacritic": ("Metacritic", "Metacritic")
        case "trakt": ("Trakt", "Trakt")
        default: (rating.source, rating.source)
        }
        let text = switch rating.source {
        case "rottenTomatoes":
            "\(Int(rating.value.rounded()))%"
        case "metacritic":
            "\(Int(rating.value.rounded()))"
        default:
            rating.value.formatted(.number.precision(.fractionLength(1)).locale(locale))
        }
        return RatingChip(label: names.label, name: names.name, text: text)
    }
}
