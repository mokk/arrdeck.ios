import ArrdeckAPI
import ArrdeckData
import Foundation
import Testing

@Suite struct ReleaseQueryTests {
    func release(_ guid: String, title: String = "Some.Movie.2160p", approved: Bool? = true, quality: String? = nil, group: String? = nil,
                 score: Int? = nil, size: Int? = nil, seeders: Int? = nil, age: Double? = nil) -> ArrRelease {
        .init(age_days: age, approved: approved, custom_format_score: score, guid: guid, indexer_id: 1, quality: quality,
              release_group: group, seeders: seeders, size: size, title: title)
    }

    func guids(_ releases: [ArrRelease]) -> [String] { releases.map(\.guid) }

    // MARK: sort

    @Test func bestKeepsTheServersOrder() {
        let rows = [release("a", seeders: 1), release("b", seeders: 9), release("c", seeders: 5)]
        #expect(guids(ReleaseQuery.sort(rows, by: .best)) == ["a", "b", "c"])
    }

    @Test func scoreSortsHighestFirstThenSeeders() {
        let rows = [release("a", score: 10, seeders: 1), release("b", score: 100, seeders: 1), release("c", score: 10, seeders: 7),
                    release("d", score: nil, seeders: 3), release("e", score: -50, seeders: 99)]
        // a missing score counts as 0
        #expect(guids(ReleaseQuery.sort(rows, by: .score)) == ["b", "c", "a", "d", "e"])
    }

    @Test func sizeAndSeedersSortLargestFirstWithMissingLast() {
        let rows = [release("a", size: 5, seeders: nil), release("b", size: nil, seeders: 2), release("c", size: 9, seeders: 8)]
        #expect(guids(ReleaseQuery.sort(rows, by: .size)) == ["c", "a", "b"])
        #expect(guids(ReleaseQuery.sort(rows, by: .seeders)) == ["c", "b", "a"])
    }

    @Test func ageSortsNewestFirstWithUnknownLast() {
        let rows = [release("a", age: 30), release("b", age: nil), release("c", age: 0.5)]
        #expect(guids(ReleaseQuery.sort(rows, by: .age)) == ["c", "a", "b"])
    }

    @Test func rejectedAlwaysSinkBelowApprovedWhateverTheSort() {
        let rows = [release("bad-big", approved: false, score: 999, size: 99, seeders: 99, age: 0),
                    release("ok-small", approved: true, score: 1, size: 1, seeders: 1, age: 90)]
        for order in ReleaseSort.allCases {
            #expect(guids(ReleaseQuery.sort(rows, by: order)) == ["ok-small", "bad-big"], "\(order)")
        }
    }

    @Test func aMissingApprovalIsNotARejection() {
        #expect(!ReleaseQuery.isRejected(release("a", approved: nil)))
        #expect(ReleaseQuery.isRejected(release("a", approved: false)))
    }

    @Test func equalKeysKeepTheirOrder() {
        let rows = (0..<20).map { release("r\($0)", size: 5) }
        #expect(guids(ReleaseQuery.sort(rows, by: .size)) == rows.map(\.guid))
    }

    // MARK: filter

    @Test func filtersByQualityGroupAndApproval() {
        let rows = [release("a", approved: true, quality: "Bluray-2160p", group: "FraMeSToR"),
                    release("b", approved: false, quality: "Bluray-2160p", group: "NTb"),
                    release("c", approved: true, quality: "WEBDL-1080p", group: "NTb")]
        #expect(guids(ReleaseQuery.filter(rows, .init(quality: "Bluray-2160p"))) == ["a", "b"])
        #expect(guids(ReleaseQuery.filter(rows, .init(group: "NTb"))) == ["b", "c"])
        #expect(guids(ReleaseQuery.filter(rows, .init(approvedOnly: true))) == ["a", "c"])
        #expect(guids(ReleaseQuery.filter(rows, .init(quality: "Bluray-2160p", group: "NTb"))) == ["b"])
    }

    @Test func filtersBySizeRangeInclusively() {
        let rows = [release("a", size: 1000), release("b", size: 2000), release("c", size: 3000), release("d", size: nil)]
        #expect(guids(ReleaseQuery.filter(rows, .init(minBytes: 2000))) == ["b", "c"])
        #expect(guids(ReleaseQuery.filter(rows, .init(maxBytes: 2000))) == ["a", "b", "d"])
        #expect(guids(ReleaseQuery.filter(rows, .init(minBytes: 1500, maxBytes: 2500))) == ["b"])
    }

    @Test func everyTitleWordMustAppearInAnyOrder() {
        let rows = [release("a", title: "Dune.2021.2160p.UHD.BluRay.REMUX"), release("b", title: "Dune.2021.1080p.WEB-DL")]
        #expect(guids(ReleaseQuery.filter(rows, .init(text: "2160p remux"))) == ["a"])
        #expect(guids(ReleaseQuery.filter(rows, .init(text: "  REMUX   dune "))) == ["a"])
        #expect(guids(ReleaseQuery.filter(rows, .init(text: "dune"))) == ["a", "b"])
        #expect(ReleaseQuery.filter(rows, .init(text: "dune 720p")).isEmpty)
    }

    @Test func noFiltersIsInactiveAndChangesNothing() {
        #expect(!ReleaseFilters().isActive)
        #expect(ReleaseFilters(approvedOnly: true).isActive)
        #expect(ReleaseFilters(text: "x").isActive)
        let rows = [release("a"), release("b", approved: false)]
        #expect(guids(ReleaseQuery.filter(rows, ReleaseFilters())) == ["a", "b"])
    }

    @Test func applyFiltersThenSorts() {
        let rows = [release("a", approved: true, size: 1, seeders: 1), release("b", approved: false, size: 9, seeders: 9),
                    release("c", approved: true, size: 5, seeders: 5), release("d", title: "other", approved: true, size: 7)]
        let out = ReleaseQuery.apply(rows, filters: .init(text: "movie"), sort: .size)
        #expect(guids(out) == ["c", "a", "b"])
    }

    @Test func distinctValuesAreSortedDedupedAndDropEmpties() {
        let rows = [release("a", quality: "WEBDL-1080p"), release("b", quality: "Bluray-2160p"), release("c", quality: "WEBDL-1080p"),
                    release("d", quality: nil), release("e", quality: "")]
        #expect(ReleaseQuery.distinctValues(rows, \.quality) == ["Bluray-2160p", "WEBDL-1080p"])
    }

    // MARK: display

    @Test func scoreTextCarriesItsSignAndHidesNeutral() {
        #expect(ReleaseQuery.scoreText(120) == "+120")
        #expect(ReleaseQuery.scoreText(-50) == "-50")
        #expect(ReleaseQuery.scoreText(0) == nil)
        #expect(ReleaseQuery.scoreText(nil) == nil)
    }

    @Test func tagsListFormatsThenLanguagesThenEdition() {
        let full = ArrRelease(custom_formats: ["HDR", "Atmos"], edition: "Director's Cut", full_season: false, guid: "g", indexer_id: 1,
                              languages: ["English", "Danish"], title: "t")
        #expect(ReleaseQuery.tags(full) == ["HDR", "Atmos", "English", "Danish", "Director's Cut"])
        #expect(ReleaseQuery.tags(release("g")).isEmpty)
        let pack = ArrRelease(full_season: true, guid: "g", indexer_id: 1, title: "t")
        #expect(ReleaseQuery.tags(pack).count == 1)
    }

    @Test func sizeTextIsGigabytesInTheShownUnit() {
        #expect(ReleaseQuery.bytes(gb: "2", style: .binary) == 2 * 1024 * 1024 * 1024)
        #expect(ReleaseQuery.bytes(gb: "2", style: .decimal) == 2_000_000_000)
        #expect(ReleaseQuery.bytes(gb: "1,5", style: .decimal) == 1_500_000_000)
        #expect(ReleaseQuery.bytes(gb: " 0.5 ", style: .decimal) == 500_000_000)
        #expect(ReleaseQuery.bytes(gb: "", style: .binary) == nil)
        #expect(ReleaseQuery.bytes(gb: "1.", style: .decimal) == 1_000_000_000)
        #expect(ReleaseQuery.bytes(gb: "abc", style: .binary) == nil)
        #expect(ReleaseQuery.bytes(gb: "-3", style: .binary) == nil)
    }
}
