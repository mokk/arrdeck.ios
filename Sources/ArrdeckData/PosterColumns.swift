import Foundation

/// How many posters fit across, and how wide each is so the row spans the
/// whole width — margin to margin on every phone, rather than fixed-width
/// columns packed to the left with the slack on the right.
public struct PosterColumns: Equatable, Sendable {
    public static let target: CGFloat = 110
    public static let gap: CGFloat = 14

    public let count: Int
    public let poster: CGFloat

    public init(width: CGFloat) {
        // as many as fit at the target size, never fewer than two
        count = max(2, Int((width + Self.gap) / (Self.target + Self.gap)))
        poster = width > 0 ? ((width - CGFloat(count - 1) * Self.gap) / CGFloat(count)).rounded(.down) : Self.target
    }
}
