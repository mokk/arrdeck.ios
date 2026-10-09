import Foundation
import Testing
@testable import ArrdeckData

struct PosterColumnsTests {
    /// The row's width once laid out: posters plus the gaps between them.
    func used(_ fit: PosterColumns) -> CGFloat {
        CGFloat(fit.count) * fit.poster + CGFloat(fit.count - 1) * PosterColumns.gap
    }

    @Test(arguments: [350.0, 353.0, 380.0, 393.0, 440.0, 700.0])
    func aRowFillsTheWidthToWithinAPoint(width: CGFloat) {
        let fit = PosterColumns(width: width)
        #expect(used(fit) <= width)
        #expect(width - used(fit) < CGFloat(fit.count), "slack is only the rounding")
    }

    @Test func postersStayNearTheTargetSize() {
        // an iPhone Air's content width, and a small phone's
        #expect(PosterColumns(width: 380).count == 3)
        #expect(PosterColumns(width: 380).poster == 117)
        #expect(PosterColumns(width: 335).count == 2, "two wide rather than three cramped")
        #expect(PosterColumns(width: 700).count == 5)
    }

    @Test func beforeTheFirstMeasurementTheTargetSizeIsUsed() {
        #expect(PosterColumns(width: 0).poster == PosterColumns.target)
    }
}
