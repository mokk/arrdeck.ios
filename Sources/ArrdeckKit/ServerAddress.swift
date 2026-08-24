import Foundation

/// Turns what a person types into a probe-able base URL.
public enum ServerAddress {
    /// "10.0.0.154:3500" → http://10.0.0.154:3500, "deck.example.com" →
    /// https://deck.example.com.
    ///
    /// The scheme default splits on purpose: a bare IP or localhost is a LAN
    /// deployment, which in practice runs plain HTTP (and is why the app ships
    /// an NSAllowsLocalNetworking ATS exception), while a hostname implies a
    /// reverse proxy with TLS. Guessing https for a LAN IP would fail the
    /// probe with a TLS error a user cannot act on.
    public static func normalise(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if !text.contains("://") {
            let host = text.split(separator: ":").first.map(String.init) ?? text
            text = (isLANHost(host) ? "http://" : "https://") + text
        }

        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }

        // The base URL is stored and compared, so it has to be canonical:
        // no trailing slash, no path (arrdeck serves at the root), lowercased
        // scheme and host.
        components.scheme = scheme
        components.host = host.lowercased()
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    static func isLANHost(_ host: String) -> Bool {
        if host == "localhost" { return true }
        // An IPv4 literal. IPv6 literals arrive bracketed and are rare enough
        // on home LANs that they can take the https default and a manual
        // scheme when needed.
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { UInt8($0) != nil }
    }
}
