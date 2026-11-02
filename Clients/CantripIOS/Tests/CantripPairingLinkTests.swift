import Foundation
import XCTest
@testable import Hermes

/// `cantripagent://pair` links from `cantrip pair`: what parses, what is refused, and that the
/// existing tab links are unaffected.
@MainActor
final class CantripPairingLinkTests: XCTestCase {
    /// 43 base64url characters, the shape of a host's 32-byte pairing token.
    private let token = "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-_AbCdE"

    /// RFC 3986 unreserved characters stay; everything else is percent-encoded.
    private func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        ))!
    }

    private func link(_ items: [(String, String)], scheme: String = "cantripagent", host: String = "pair",
                      path: String = "") throws -> URL {
        let query = items.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
        return try XCTUnwrap(URL(string: "\(scheme)://\(host)\(path)?\(query)"))
    }

    private func parse(_ items: [(String, String)]) throws -> Result<CantripPairingLink, CantripPairingLinkError>? {
        CantripPairingLink.parse(try link(items))
    }

    private func error(_ items: [(String, String)], file: StaticString = #filePath,
                       line: UInt = #line) throws -> CantripPairingLinkError? {
        let result = try XCTUnwrap(try parse(items), "Not recognized as a pairing link", file: file, line: line)
        guard case .failure(let error) = result else {
            XCTFail("Expected the link to be refused", file: file, line: line)
            return nil
        }
        return error
    }

    func testFullLinkParsesEveryRouteAndNormalizesThem() throws {
        let result = try XCTUnwrap(try parse([
            ("v", "1"), ("name", "mac-mini"), ("token", token),
            ("url", "https://Mac-Mini.example-tailnet.ts.net:443/"), ("direct", "192.168.0.10:8766"),
            ("tailscaleOnly", "1"),
        ]))
        let pairing = try result.get()
        XCTAssertEqual(pairing, CantripPairingLink(
            name: "mac-mini", token: token, url: "https://mac-mini.example-tailnet.ts.net",
            directAddress: "192.168.0.10:8766", tailscaleOnly: true
        ))
        XCTAssertEqual(pairing.urlHost, "mac-mini.example-tailnet.ts.net")
        XCTAssertEqual(pairing.draft, ServerDraft(
            name: "mac-mini", url: "https://mac-mini.example-tailnet.ts.net", credential: token,
            tailscaleOnly: true, directAddress: "192.168.0.10:8766"
        ))
        XCTAssertEqual(pairing.tokenSuffix, "bCdE")
        XCTAssertFalse(String(describing: pairing).contains(token), "Logs never show the whole token")
        XCTAssertFalse(String(reflecting: pairing).contains(token))
    }

    func testTokenOnlyLinkReliesOnLocalNetworkDiscovery() throws {
        let pairing = try XCTUnwrap(try parse([("v", "1"), ("token", token)])).get()
        XCTAssertNil(pairing.name)
        XCTAssertNil(pairing.url)
        XCTAssertNil(pairing.urlHost)
        XCTAssertNil(pairing.directAddress)
        XCTAssertFalse(pairing.tailscaleOnly)
        XCTAssertEqual(pairing.displayName, "Cantrip on LAN")
        XCTAssertEqual(pairing.draft, ServerDraft(credential: token))
        let unknownFieldsIgnored = try XCTUnwrap(try parse([("v", "1"), ("token", token), ("future", "x")])).get()
        XCTAssertEqual(unknownFieldsIgnored, pairing)
    }

    func testPercentEncodedValuesRoundTrip() throws {
        let name = "the user's Mac & Co = ü 🧙"
        let url = "https://abc-8765.app.github.dev"
        let direct = "[fe80::1%en0]:8766"
        let expected = CantripPairingLink(name: name, token: token, url: url, directAddress: direct, tailscaleOnly: false)
        let items = [("v", "1"), ("name", name), ("token", token), ("url", url), ("direct", direct)]
        XCTAssertEqual(try XCTUnwrap(try parse(items)).get(), expected)

        var components = URLComponents()
        components.scheme = CantripDeepLink.scheme
        components.host = CantripPairingLink.host
        components.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        let foundationEncoded = try XCTUnwrap(components.url)
        XCTAssertEqual(try XCTUnwrap(CantripPairingLink.parse(foundationEncoded)).get(), expected)
        let uppercased = try XCTUnwrap(URL(string: foundationEncoded.absoluteString
            .replacingOccurrences(of: "cantripagent://pair", with: "CANTRIPAGENT://PAIR")))
        XCTAssertEqual(try XCTUnwrap(CantripPairingLink.parse(uppercased)).get(), expected)
    }

    func testNameIsOneReadableLineOfAtMostEightyCharacters() throws {
        func name(_ raw: String) throws -> String? {
            try XCTUnwrap(try parse([("v", "1"), ("token", token), ("name", raw)])).get().name
        }
        XCTAssertEqual(try name("  codespaces-abc123\n"), "codespaces-abc123")
        XCTAssertEqual(try name("work\tlaptop\u{202E}evil"), "work laptop evil")
        XCTAssertEqual(try name(String(repeating: "m", count: 100)), String(repeating: "m", count: 80))
        XCTAssertNil(try name("   "))
    }

    func testTokensMustBeBase64URLOfThirtyTwoToOneHundredTwentyEightCharacters() throws {
        let valid = [String(repeating: "a", count: 32), String(repeating: "Z9_-", count: 32)]
        for value in valid {
            XCTAssertEqual(try XCTUnwrap(try parse([("v", "1"), ("token", value)])).get().token, value)
        }
        let invalid = [
            "", String(repeating: "a", count: 31), String(repeating: "a", count: 129),
            String(token.dropLast()) + "+", String(token.dropLast()) + "/", String(token.dropLast()) + "=",
            String(token.dropLast()) + " ", String(token.dropLast()) + "é",
        ]
        for value in invalid {
            XCTAssertEqual(try error([("v", "1"), ("token", value)]), .invalidToken, "Accepted \(value.debugDescription)")
        }
        XCTAssertEqual(try error([("v", "1")]), .invalidToken)
        XCTAssertTrue(CantripPairingLinkError.invalidToken.localizedDescription.contains("cantrip pair"))
    }

    func testURLsFollowTheRemoteSettingsRules() throws {
        for url in ["http://mac-mini.local", "https://host.example/api", "https://user:secret@host.example",
                    "ftp://host.example"] {
            guard case .invalidURL(let reason)? = try error([("v", "1"), ("token", token), ("url", url)]) else {
                XCTFail("Accepted \(url)")
                continue
            }
            XCTAssertFalse(reason.isEmpty)
        }
        let http = try error([("v", "1"), ("token", token), ("url", "http://mac-mini.local")])
        XCTAssertTrue(http?.localizedDescription.contains("Use HTTPS") == true)
        // Loopback HTTP stays allowed for simulator development, as in Settings.
        let loopback = try XCTUnwrap(try parse([("v", "1"), ("token", token), ("url", "http://127.0.0.1:8765")])).get()
        XCTAssertEqual(loopback.url, "http://127.0.0.1:8765")
        let empty = try XCTUnwrap(try parse([("v", "1"), ("token", token), ("url", "")])).get()
        XCTAssertNil(empty.url)
    }

    func testDirectAddressesMustBeHostAndPort() throws {
        for direct in ["192.168.0.10", "192.168.0.10:0", "192.168.0.10:port", "a:b:c", "bad host:8766"] {
            XCTAssertEqual(try error([("v", "1"), ("token", token), ("direct", direct)]), .invalidDirectAddress,
                           "Accepted \(direct)")
        }
        let direct = try XCTUnwrap(try parse([("v", "1"), ("token", token), ("direct", "Work-Laptop.local:8766")])).get()
        XCTAssertEqual(direct.directAddress, "work-laptop.local:8766")
        XCTAssertEqual(direct.displayName, "work-laptop.local:8766")
    }

    func testTailscaleOnlyNeedsAURL() throws {
        XCTAssertEqual(try error([("v", "1"), ("token", token), ("tailscaleOnly", "1")]), .tailscaleOnlyWithoutURL)
        XCTAssertEqual(try error([("v", "1"), ("token", token), ("direct", "192.168.0.10:8766"), ("tailscaleOnly", "1")]),
                       .tailscaleOnlyWithoutURL)
        XCTAssertEqual(try error([("v", "1"), ("token", token), ("url", "https://a.example"), ("tailscaleOnly", "yes")]),
                       .malformed)
        let off = try XCTUnwrap(try parse([("v", "1"), ("token", token), ("tailscaleOnly", "0")])).get()
        XCTAssertFalse(off.tailscaleOnly)
    }

    func testNewerVersionsAskForAnUpdateAndMissingVersionsAreRefused() throws {
        XCTAssertEqual(try error([("v", "2"), ("token", token)]), .unsupportedVersion)
        XCTAssertEqual(try error([("v", "2"), ("token", "not a token"), ("future", "field")]), .unsupportedVersion)
        #if os(macOS)
        XCTAssertEqual(CantripPairingLinkError.unsupportedVersion.localizedDescription,
                       "Update Cantrip Gateway to pair with this Mac.")
        #else
        XCTAssertEqual(CantripPairingLinkError.unsupportedVersion.localizedDescription,
                       "Update Cantrip Agent to pair with this Mac.")
        #endif
        for version in [nil, "", "0", "-1", "one", "1.0"] {
            var items = [("token", token)]
            if let version { items.append(("v", version)) }
            XCTAssertEqual(try error(items), .malformed, "Accepted version \(version ?? "nil")")
        }
    }

    func testOnlyCantripPairLinksAreClaimed() throws {
        let items = [("v", "1"), ("token", token)]
        XCTAssertNil(CantripPairingLink.parse(try link(items, scheme: "https")))
        XCTAssertNil(CantripPairingLink.parse(try link(items, scheme: "cantrip")))
        XCTAssertNil(CantripPairingLink.parse(try link(items, host: "pairing")))
        XCTAssertNil(CantripPairingLink.parse(try link(items, host: "tabs")))
        XCTAssertEqual(CantripPairingLink.parse(try link(items, path: "/extra")), .failure(.malformed))
        XCTAssertEqual(CantripPairingLink.parse(try link(items, path: "/")).map { $0.map(\.token) }, .success(token))
        XCTAssertEqual(try error(items + [("token", String(repeating: "b", count: 43))]), .malformed,
                       "Two tokens are ambiguous")
        XCTAssertEqual(try error(items + [("url", "https://a.example"), ("url", "https://b.example")]), .malformed)
    }

    func testTabLinksStillParseAndArentPairingLinks() throws {
        let tab = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
        XCTAssertEqual(CantripDeepLink.parse(CantripDeepLink.tab(tab, serverID: "server")), .tab(id: tab, serverID: "server"))
        XCTAssertEqual(CantripDeepLink.parse(CantripDeepLink.tabs(serverID: nil)), .tabs(serverID: nil))
        XCTAssertNil(CantripPairingLink.parse(CantripDeepLink.tab(tab, serverID: nil)))
        XCTAssertNil(CantripPairingLink.parse(CantripDeepLink.tabs(serverID: nil)))
        XCTAssertNil(CantripDeepLink.parse(try link([("v", "1"), ("token", token)])))
    }
}
