import Foundation
import XCTest
@testable import Hermes

private final class SettingsRequestProtocol: URLProtocol {
    @MainActor static var handler: ((URLRequest) throws -> (Int, Data))?
    private var responseTask: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { responseTask?.cancel() }
    override func startLoading() {
        responseTask = Task { @MainActor in
            do {
                let handler = try XCTUnwrap(Self.handler)
                let (status, data) = try handler(request)
                let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url),
                    statusCode: status, httpVersion: nil, headerFields: nil))
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
}

/// The Mac's settings manifest as clients read and change it (`/api/v1/settings`).
@MainActor
final class CantripSettingsManifestTests: XCTestCase {
    /// The host contract's shape, trimmed (invented values).
    static let payload = """
    {
      "version": 1, "revision": "abc123", "mac": "Studio", "local": false,
      "pages": [
        {"id": "macs", "title": "Macs", "sections": [
          {"id": "remote", "title": "Remote control on Studio", "fields": [
            {"key": "remoteControlEnabled", "type": "toggle", "label": "Remote control", "value": true,
             "readOnly": true, "readOnlyReason": "Change this in Cantrip's Settings on the Mac."},
            {"key": "remoteLANPort", "type": "port", "label": "Direct port", "value": 0, "min": 0, "max": 65535,
             "zeroLabel": "Automatic", "guarded": true, "visibleWhen": {"key": "remoteControlEnabled", "values": [true]}},
            {"key": "rotatePairingToken", "type": "action", "label": "Replace Pairing Token", "destructive": true,
             "confirmation": "Every other device has to pair again."}
          ]}
        ]},
        {"id": "home", "title": "Home & tabs", "sections": [
          {"id": "home", "title": "Cantrip Home", "fields": [
            {"key": "cantripHomeEnabled", "type": "toggle", "label": "Cantrip Home", "value": false},
            {"key": "cantripHomeParallelRuns", "type": "integer", "label": "Background jobs at once", "value": 3,
             "min": 1, "max": 6, "step": 1, "visibleWhen": {"key": "cantripHomeEnabled", "values": [true]}}
          ]},
          {"id": "tabs", "title": "Tabs", "fields": [
            {"key": "copilotIdleReleaseMinutes", "type": "choice", "label": "Free idle memory after", "value": 30,
             "choices": [{"value": 10, "label": "10 minutes"}, {"value": 30, "label": "30 minutes"}, {"value": 0, "label": "Never"}]},
            {"key": "claudeWorkdir", "type": "path", "label": "Default working folder", "value": "~/Coding", "maxLength": 1024}
          ]}
        ]},
        {"id": "models", "title": "Models", "sections": [
          {"id": "copilot", "title": "Copilot", "link": true, "summary": "gpt-5 · high", "fields": [
            {"key": "copilotEffort", "type": "choice", "label": "Effort", "value": "high", "choices": [
              {"value": "", "label": "Default"}, {"value": "high", "label": "High"},
              {"value": "max", "label": "Max (not supported)", "disabled": true}]},
            {"key": "localAPIKey", "type": "secret", "label": "API key", "isSet": true, "maxLength": 4096},
            {"key": "panelOpacity", "type": "number", "label": "Panel opacity", "value": 1, "min": 0.5, "max": 1,
             "step": 0.05, "format": "percent"},
            {"key": "future", "type": "slider3d", "label": "Something new", "value": "x"}
          ]}
        ]}
      ],
      "pending": {"id": "p1", "keys": ["remoteLANPort"], "summary": "Direct port 8766", "secondsLeft": 42,
                  "revertsAt": "2026-11-02T12:00:00Z"}
    }
    """

    private func manifest() throws -> CantripSettingsManifest {
        try JSONDecoder().decode(CantripSettingsManifest.self, from: Data(Self.payload.utf8))
    }

    func testFieldsDecodeWithTheirTypesAndRules() throws {
        let manifest = try manifest()
        XCTAssertEqual(manifest.pages.map(\.id), ["macs", "home", "models"])
        XCTAssertEqual(manifest.pending?.summary, "Direct port 8766")
        let port = try XCTUnwrap(manifest.field("remoteLANPort"))
        XCTAssertEqual(port.type, .port)
        XCTAssertEqual(port.value, .int(0))
        XCTAssertEqual(port.display(port.value), "Automatic")
        XCTAssertTrue(manifest.isVisible(port), "Remote control is on")
        XCTAssertTrue(try XCTUnwrap(manifest.field("remoteControlEnabled")).isReadOnly)
        let runs = try XCTUnwrap(manifest.field("cantripHomeParallelRuns"))
        XCTAssertFalse(manifest.isVisible(runs), "hidden while Cantrip Home is off")
        XCTAssertEqual(manifest.visibleFields(manifest.page("home")!.sections[0]).map(\.key), ["cantripHomeEnabled"])
        let idle = try XCTUnwrap(manifest.field("copilotIdleReleaseMinutes"))
        XCTAssertEqual(idle.display(.int(0)), "Never")
        let effort = try XCTUnwrap(manifest.field("copilotEffort"))
        XCTAssertEqual(effort.offeredChoices.map(\.label), ["Default", "High"], "unsupported choices aren't offered")
        XCTAssertEqual(try XCTUnwrap(manifest.field("localAPIKey")).isSet, true)
        XCTAssertNil(manifest.field("localAPIKey")?.value, "a secret's value never arrives")
        let opacity = try XCTUnwrap(manifest.field("panelOpacity"))
        XCTAssertEqual(opacity.value?.double, 1, "a whole number arrives as an integer")
        XCTAssertEqual(opacity.display(.double(0.7)), "70%")
        XCTAssertEqual(manifest.field("future")?.type, .unknown, "newer field types still decode")
        XCTAssertTrue(CantripSettingValue.int(1).matches(.double(1)))
        XCTAssertFalse(CantripSettingValue.bool(true).matches(.int(1)))
    }

    func testChangesKeepTheirJSONTypes() throws {
        let body = try CantripSettingsChange.set(["cantripHomeParallelRuns": .int(2), "linkPreviewsEnabled": .bool(false),
                                                  "claudeWorkdir": .string("~/Work"), "panelOpacity": .double(0.75)],
                                                 revision: "abc123").body
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["revision"] as? String, "abc123")
        let changes = try XCTUnwrap(object["changes"] as? [String: Any])
        XCTAssertEqual(changes["cantripHomeParallelRuns"] as? Int, 2)
        XCTAssertEqual((changes["linkPreviewsEnabled"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() }, true)
        XCTAssertEqual(changes["claudeWorkdir"] as? String, "~/Work")
        XCTAssertEqual(changes["panelOpacity"] as? Double, 0.75)
        for (change, key) in [(CantripSettingsChange.action("rotatePairingToken"), "action"), (.keep("p1"), "keep"), (.revert("p1"), "revert")] {
            let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: try change.body) as? [String: String])
            XCTAssertEqual(sent.keys.first, key)
        }
    }

    private func client() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SettingsRequestProtocol.self]
        let client = URLSession(configuration: configuration)
        addTeardownBlock { @MainActor in
            client.invalidateAndCancel()
            SettingsRequestProtocol.handler = nil
        }
        return client
    }

    func testTheAPIReadsSavesAndSaysWhenTheMacIsOlder() async throws {
        let session = client()
        var seen: [URLRequest] = []
        SettingsRequestProtocol.handler = { request in
            seen.append(request)
            if request.httpMethod == "POST" {
                let reply = Self.payload.dropLast(2) + #", "result": {"message": "Replaced.", "pairingToken": "new-token"}}"#
                return (200, Data(reply.utf8))
            }
            return (200, Data(Self.payload.utf8))
        }
        let api = CantripRemoteAPI(transport: .remote(try XCTUnwrap(URL(string: "https://studio.example"))),
                                   token: "settings-test-token", urlSession: session)
        let loaded = try await api.settings()
        XCTAssertEqual(loaded.revision, "abc123")
        XCTAssertNil(seen.last?.value(forHTTPHeaderField: "X-Cantrip-Local-Key"), "only Cantrip's own window sends the key")

        SettingsRequestProtocol.handler = { _ in (404, Data(#"{"error":"not found"}"#.utf8)) }
        do {
            _ = try await api.settings()
            XCTFail("an older Mac answers 404")
        } catch CantripRemoteError.settingsUnsupported {}

        // Cantrip.app's Home window registers its key for This Mac's loopback address only.
        CantripLocalClientKey.register("local-key", for: "http://127.0.0.1:8765")
        CantripLocalClientKey.register("ignored", for: "https://studio.example")
        addTeardownBlock { CantripLocalClientKey.register(nil, for: "http://127.0.0.1:8765") }
        XCTAssertEqual(CantripLocalClientKey.key(for: try XCTUnwrap(URL(string: "http://127.0.0.1:8765/api/v1/settings"))), "local-key")
        XCTAssertNil(CantripLocalClientKey.key(for: try XCTUnwrap(URL(string: "http://127.0.0.1:9999/api/v1/settings"))))
        XCTAssertNil(CantripLocalClientKey.key(for: try XCTUnwrap(URL(string: "https://studio.example/api/v1/settings"))))
        SettingsRequestProtocol.handler = { request in
            seen.append(request)
            return (200, Data(Self.payload.utf8))
        }
        let local = CantripRemoteAPI(transport: .remote(try XCTUnwrap(URL(string: "http://127.0.0.1:8765"))),
                                     token: "settings-test-token", urlSession: session)
        _ = try await local.settings()
        XCTAssertEqual(seen.last?.value(forHTTPHeaderField: "X-Cantrip-Local-Key"), "local-key")
    }

    func testAReplyCarriesTheManifestAndTheButtonsAnswer() throws {
        let reply = Self.payload.dropLast(2) + #", "result": {"message": "Copy it now.", "copy": "sk-123"}}"#
        let decoded = try JSONDecoder().decode(CantripSettingsReply.self, from: Data(reply.utf8))
        XCTAssertEqual(decoded.manifest.revision, "abc123")
        XCTAssertEqual(decoded.result?.copy, "sk-123")
        XCTAssertTrue(decoded.result?.showsSheet == true)
        let plain = try JSONDecoder().decode(CantripSettingsReply.self, from: Data(Self.payload.utf8))
        XCTAssertNil(plain.result)
    }
}
