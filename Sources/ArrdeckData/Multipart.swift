import Foundation

/// A multipart/form-data body, for the one upload the generated client does
/// not cover: a .torrent file to `/torrents/{client}/add-file`.
public struct MultipartForm: Sendable {
    public let boundary: String
    private var body = Data()

    public init(boundary: String = "arrdeck-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public mutating func addField(_ name: String, value: String) {
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
    }

    public mutating func addFile(_ name: String, filename: String, contentType: String, data: Data) {
        let safeName = filename.replacingOccurrences(of: "\"", with: "'")
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(safeName)\"\r\nContent-Type: \(contentType)\r\n\r\n")
        body.append(data)
        body.append("\r\n")
    }

    /// The finished body, closing boundary included.
    public var encoded: Data {
        var out = body
        out.append("--\(boundary)--\r\n")
        return out
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
