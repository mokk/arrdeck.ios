import Foundation

/// Fetches a file and parks it in the app's temporary folder, where the share
/// sheet can hand it to Books or Files. Books come straight from our Readarr
/// fork, which serves the bytes; its key is in the address.
@MainActor @Observable
public final class FileDownloadModel {
    public enum State: Equatable, Sendable {
        case idle
        case downloading
        case done(URL)
        case failed(String)
    }

    public private(set) var state: State = .idle
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
    }

    public func download(_ url: URL, suggestedName: String) async {
        state = .downloading
        do {
            let (temp, response) = try await session.download(from: url)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard (200..<300).contains(http.statusCode) else { throw APIError.unexpectedStatus(http.statusCode) }
            let destination = try Self.destination(for: suggestedName)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temp, to: destination)
            state = .done(destination)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    public func reset() { state = .idle }

    /// Where a download lands: the name the server suggested, with path
    /// separators removed so a hostile name cannot escape the folder.
    public static func destination(for name: String) throws -> URL {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "book" : cleaned
        let folder = FileManager.default.temporaryDirectory.appending(path: "arrdeck-downloads", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: safe)
    }
}
