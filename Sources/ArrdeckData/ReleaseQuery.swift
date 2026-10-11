import Foundation

/// How interactive search orders its releases. A String so the sheet can keep
/// the choice with @AppStorage; the raw values are the PWA's, which keeps its
/// choice under the same names.
public enum ReleaseSort: String, CaseIterable, Sendable {
    /// The server's order: approved first, then most seeders.
    case best, score, size, seeders, age

    public var label: String {
        switch self {
        case .best: String(localized: "Best match")
        case .score: String(localized: "Custom-format score")
        case .size: String(localized: "Size")
        case .seeders: String(localized: "Seeders")
        case .age: String(localized: "Newest")
        }
    }
}

/// What the interactive-search sheet narrows its list to. Empty strings and
/// nil bounds mean "any".
public struct ReleaseFilters: Equatable, Sendable {
    public var text = ""
    public var quality = ""
    public var group = ""
    public var approvedOnly = false
    public var minBytes: Int?
    public var maxBytes: Int?

    public init(text: String = "", quality: String = "", group: String = "", approvedOnly: Bool = false,
                minBytes: Int? = nil, maxBytes: Int? = nil) {
        self.text = text
        self.quality = quality
        self.group = group
        self.approvedOnly = approvedOnly
        self.minBytes = minBytes
        self.maxBytes = maxBytes
    }

    public var isActive: Bool { self != ReleaseFilters() }
}

/// Sorting and filtering for the interactive-search sheet, kept apart from the
/// view so the ordering rules are testable. The rules are the PWA's
/// (lib/releases.ts), so both clients list the same releases the same way.
public enum ReleaseQuery {
    /// The one meaning of "rejected" the filters, the sort and the row share.
    /// The server sends `approved` as true unless the arr said otherwise, so a
    /// missing value is not a rejection.
    public static func isRejected(_ release: ArrRelease) -> Bool { release.approved == false }

    public static func filter(_ releases: [ArrRelease], _ filters: ReleaseFilters) -> [ArrRelease] {
        // every word must appear, so "2160p remux" finds the title in either order
        let words = filters.text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        return releases.filter { release in
            if filters.approvedOnly && isRejected(release) { return false }
            if !filters.quality.isEmpty && release.quality != filters.quality { return false }
            if !filters.group.isEmpty && release.release_group != filters.group { return false }
            if let min = filters.minBytes, (release.size ?? 0) < min { return false }
            if let max = filters.maxBytes, (release.size ?? 0) > max { return false }
            let title = release.title.lowercased()
            return words.allSatisfy { title.contains($0) }
        }
    }

    /// Rejected releases always sink below approved ones, whatever the sort:
    /// they stay listed (the arr's rejection is advice, and grabbing one is
    /// allowed) but should not crowd out what it would accept. Ties keep the
    /// server's order, which is all "best match" is.
    public static func sort(_ releases: [ArrRelease], by sort: ReleaseSort) -> [ArrRelease] {
        func descending(_ value: Int?, missing: Double = -.infinity) -> Double { -(value.map(Double.init) ?? missing) }
        func key(_ release: ArrRelease) -> [Double] {
            switch sort {
            case .best: []
            case .score: [descending(release.custom_format_score, missing: 0), descending(release.seeders)]
            case .size: [descending(release.size)]
            case .seeders: [descending(release.seeders)]
            // newest first; one with no age is the last to be called new
            case .age: [release.age_days ?? .infinity]
            }
        }
        let keyed = releases.enumerated().map { (index: $0.offset, release: $0.element, key: [isRejected($0.element) ? 1.0 : 0.0] + key($0.element)) }
        return keyed.sorted { a, b in
            for (x, y) in zip(a.key, b.key) where x != y { return x < y }
            return a.index < b.index
        }.map(\.release)
    }

    public static func apply(_ releases: [ArrRelease], filters: ReleaseFilters, sort order: ReleaseSort) -> [ArrRelease] {
        sort(filter(releases, filters), by: order)
    }

    /// What a filter menu offers: the values the results actually contain.
    public static func distinctValues(_ releases: [ArrRelease], _ pick: (ArrRelease) -> String?) -> [String] {
        Set(releases.compactMap(pick).filter { !$0.isEmpty }).sorted { $0.localizedCompare($1) == .orderedAscending }
    }

    /// "+120" or "-50"; nil for no score or a neutral one, which would only be noise.
    public static func scoreText(_ score: Int?) -> String? {
        guard let score, score != 0 else { return nil }
        return score > 0 ? "+\(score)" : "\(score)"
    }

    /// The extras under a release: custom formats, languages, edition and
    /// whether it is a whole season.
    public static func tags(_ release: ArrRelease) -> [String] {
        (release.custom_formats ?? []) + (release.languages ?? [])
            + [release.edition].compactMap { $0 }.filter { !$0.isEmpty }
            + (release.full_season == true ? [String(localized: "Season pack")] : [])
    }

    /// A size typed in GB, in whichever GB sizes are shown in (1000 or 1024
    /// MB); nil when empty, not a number or negative, so a half-typed "1." or
    /// a stray letter does not narrow the list to nothing.
    public static func bytes(gb text: String, style: SizeStyle) -> Int? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(cleaned), value >= 0, value.isFinite else { return nil }
        let base: Double = style == .decimal ? 1000 : 1024
        return Int(value * base * base * base)
    }
}
