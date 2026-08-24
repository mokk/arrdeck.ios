import Foundation
import Testing
@testable import ArrdeckKit

/// What a person types becomes the profile's permanent identity, so the
/// normalisation rules are contract, not convenience.
struct ServerAddressTests {
    @Test func bareIPGetsHTTP() {
        // LAN deployments run plain HTTP; defaulting a LAN IP to https would
        // fail the probe with a TLS error the user cannot act on.
        #expect(
            ServerAddress.normalise("10.0.0.154:3500")?.absoluteString
                == "http://10.0.0.154:3500"
        )
    }

    @Test func localhostGetsHTTP() {
        #expect(
            ServerAddress.normalise("localhost:3500")?.absoluteString
                == "http://localhost:3500"
        )
    }

    @Test func hostnameGetsHTTPS() {
        // A hostname implies a reverse proxy with TLS.
        #expect(
            ServerAddress.normalise("deck.example.com")?.absoluteString
                == "https://deck.example.com"
        )
    }

    @Test func explicitSchemeIsRespected() {
        // Someone running plain HTTP behind a hostname can say so.
        #expect(
            ServerAddress.normalise("http://deck.example.com")?.absoluteString
                == "http://deck.example.com"
        )
    }

    @Test func trailingSlashAndPathAreStripped() {
        // The base URL is stored and compared; arrdeck serves at the root, so a
        // pasted deep link must not create a distinct-looking profile.
        #expect(
            ServerAddress.normalise("https://deck.example.com/manage?x=1")?.absoluteString
                == "https://deck.example.com"
        )
    }

    @Test func hostIsCanonicalisedToLowercase() {
        #expect(
            ServerAddress.normalise("HTTPS://Deck.Example.COM")?.absoluteString
                == "https://deck.example.com"
        )
    }

    @Test func whitespaceFromAPasteIsTolerated() {
        #expect(
            ServerAddress.normalise("  deck.example.com\n")?.absoluteString
                == "https://deck.example.com"
        )
    }

    @Test func garbageIsRejectedNotGuessedAt() {
        #expect(ServerAddress.normalise("") == nil)
        #expect(ServerAddress.normalise("   ") == nil)
        #expect(ServerAddress.normalise("ftp://deck.example.com") == nil)
        #expect(ServerAddress.normalise("http://") == nil)
    }

    @Test func almostAnIPIsAHostnameNotAnIP() {
        // "10.0.0.notanoctet" and 5-part strings must not take the http default.
        #expect(ServerAddress.normalise("10.0.0.deck")?.scheme == "https")
        #expect(!ServerAddress.isLANHost("10.0.0.300"))
        #expect(!ServerAddress.isLANHost("1.2.3.4.5"))
    }
}
