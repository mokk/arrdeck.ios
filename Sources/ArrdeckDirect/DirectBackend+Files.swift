import ArrdeckData
import Foundation

extension DirectBackend: FileAddressAPI {
    /// The fork's own download endpoint, carrying the key: the download runs
    /// in a session of its own, which cannot be handed the header.
    public func bookFileURL(book _: Int, file: Int) -> URL? {
        guard let readarr = try? registry.arr("readarr") else { return nil }
        return readarr.url("/bookfile/\(file)/download", query: ["apikey": registry.connection("readarr").apiKey])
    }
}
