import Foundation

/// Whether the chrome over a page — the tab bar and the page's own actions —
/// is out, from how the page scrolls. Scrolling down a little folds it away;
/// it comes back only after a deliberate scroll up, so nudging back past
/// something does not bring it. Near the top, or on a page too short to
/// scroll, it is always out.
public struct ChromeScroll: Sendable, Equatable {
    /// Distances in points.
    public struct Tuning: Sendable, Equatable {
        /// Down this far, once past `nearTop`, folds the chrome away.
        public var collapseAfter: Double = 30
        /// Up this far in one go brings it back.
        public var expandAfter: Double = 100
        /// Within this of the top it is always out.
        public var nearTop: Double = 60
        /// A movement against the current direction smaller than this is
        /// jitter and keeps the distance travelled so far.
        public var deadBand: Double = 8
        /// A step larger than this is a jump — a refresh, "Today", the letter
        /// strip — not a scroll, and starts the count over.
        public var maxStep: Double = 120

        public init() {}
    }

    /// Where a page is: `offset` 0 at the top, `maxOffset` at the bottom.
    public struct Sample: Sendable, Equatable {
        public var offset: Double
        public var maxOffset: Double
        public var contentHeight: Double

        public init(offset: Double, maxOffset: Double, contentHeight: Double) {
            self.offset = offset
            self.maxOffset = maxOffset
            self.contentHeight = contentHeight
        }
    }

    public private(set) var expanded = true
    public var tuning: Tuning
    private var last: Sample?
    /// Signed distance in the current direction: positive is down.
    private var travel: Double = 0
    /// Movement against `travel` not yet past the dead band.
    private var against: Double = 0

    public init(tuning: Tuning = Tuning()) {
        self.tuning = tuning
    }

    /// Out again and the count started over: a tab switched, a screen pushed
    /// or popped.
    public mutating func reset() {
        expanded = true
        last = nil
        travel = 0
        against = 0
    }

    public mutating func scrolled(to raw: Sample) {
        // rubber-banding past either end is not a scroll
        var sample = raw
        sample.offset = min(max(raw.offset, 0), max(raw.maxOffset, 0))
        defer { last = sample }

        if sample.maxOffset <= tuning.nearTop || sample.offset <= tuning.nearTop {
            expanded = true
            travel = 0
            against = 0
            return
        }
        // the first sample, or the content grew or shrank under it (more
        // loaded, earlier days prepended): nothing to compare with
        guard let last, abs(last.contentHeight - sample.contentHeight) < 1 else {
            travel = 0
            against = 0
            return
        }
        let step = sample.offset - last.offset
        guard abs(step) <= tuning.maxStep else {
            travel = 0
            against = 0
            return
        }
        guard step != 0 else { return }

        if travel == 0 || (step > 0) == (travel > 0) {
            travel += step
            against = 0
        } else {
            against += abs(step)
            if against > tuning.deadBand {
                travel = step > 0 ? against : -against
                against = 0
            }
        }

        if expanded, travel >= tuning.collapseAfter {
            expanded = false
        } else if !expanded, -travel >= tuning.expandAfter {
            expanded = true
        }
    }
}
