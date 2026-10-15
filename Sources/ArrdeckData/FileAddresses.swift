import Foundation

/// Where a file the app downloads itself can be fetched, for a backend whose
/// addresses are not paths under one server. Without it, a file is the
/// server's to hand out, under the profile's address.
public protocol FileAddressAPI: Sendable {
    /// A book file served by the Readarr fork.
    func bookFileURL(book: Int, file: Int) -> URL?
}
