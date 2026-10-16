import ArrdeckAPI
import Foundation

extension TitleSubtitles {
    /// Anything to show at all: Bazarr tracks the title and its profile
    /// wants at least one language.
    public var hasLanguages: Bool { !(present ?? []).isEmpty || !(missing ?? []).isEmpty }
}
