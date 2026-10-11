import Foundation
import OpenAPIRuntime

/// What the backend said when it answered with a status the spec does not
/// document. "HTTP 409" tells nobody that the host helper is not set up; the
/// body does. FastAPI's own errors carry `{"detail": "…"}`, the app-wide
/// upstream handler `{"error": {"service": …, "message": …}}`.
enum ServerMessage {
    static func read(_ payload: UndocumentedPayload) async -> String? {
        guard let body = payload.body, let data = try? await Data(collecting: body, upTo: 64 * 1024) else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let detail = object["detail"] as? String, !detail.isEmpty { return detail }
        if let error = object["error"] as? [String: Any] {
            let message = (error["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if let service = error["service"] as? String, !service.isEmpty {
                return "\(Services.label(service)): \(message ?? "unreachable")"
            }
            return message
        }
        return nil
    }

    /// Seconds from a Retry-After header; the backend only sends the number form.
    static func retryAfter(_ payload: UndocumentedPayload) -> Int? {
        payload.headerFields[.retryAfter].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }
}
