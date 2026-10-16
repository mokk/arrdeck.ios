import Foundation

/// Where a file the app downloads itself can be fetched.
public protocol FileAddressAPI: Sendable {
    /// A book file served by the Readarr fork.
    func bookFileURL(book: Int, file: Int) -> URL?
}
