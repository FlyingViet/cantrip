import Foundation
import XCTest
@testable import Hermes

private final class MCPAppRequestProtocol: URLProtocol {
    @MainActor static var handler: ((URLRequest) async throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Task { @MainActor in
            do {
                let handler = try XCTUnwrap(Self.handler)
                let (status, data) = try await handler(request)
                let response = try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url), statusCode: status,
                    httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
                ))
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }
}

final class CantripMCPAppTests: XCTestCase {
    private func samplePayload(id: String = "call_1") -> MCPAppPayload {
        MCPAppPayload(
            id: id,
            serverName: "mobbin",
            toolName: "search_screens",
            title: "Screen results",
            resourceURI: "ui://mobbin/screens",
            html: "<html><head></head><body><script>window.name='ok'</script></body></html>",
            csp: MCPAppCSP(connectDomains: ["https://api.example.com"],
                           resourceDomains: ["https://cdn.example.com"],
                           frameDomains: ["https://frames.example.com"],
                           baseUriDomains: []),
            permissions: ["clipboardWrite"],
            prefersBorder: true,
            toolInput: #"{"query":"checkout"}"#,
            toolResult: #"{"content":[{"type":"text","text":"done"}]}"#,
            tool: #"{"name":"search_screens","inputSchema":{"type":"object"}}"#
        )
    }

    private func payloadData(id: String = "call_1") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "id": id,
            "serverName": "mobbin",
            "toolName": "search_screens",
            "title": "Screen results",
            "resourceURI": "ui://mobbin/screens",
            "html": "<html><head></head><body>Gallery</body></html>",
            "csp": [
                "connectDomains": ["https://api.example.com", "javascript:alert(1)"],
                "resourceDomains": ["https://cdn.example.com/", "'unsafe-inline'"],
                "frameDomains": ["https://frames.example.com"],
                "baseUriDomains": []
            ],
            "permissions": ["clipboardWrite", "camera"],
            "prefersBorder": true,
            "toolInput": #"{"query":"checkout"}"#,
            "toolResult": #"{"content":[{"type":"text","text":"done"}]}"#,
            "tool": #"{"name":"search_screens","inputSchema":{"type":"object"}}"#
        ])
    }

    func testRemoteMessageDecodesAppsOptionally() throws {
        let withApps = try JSONDecoder().decode(CantripRemoteMessage.self, from: Data(#"""
        {"id":"m1","role":"assistant","text":"","thinking":"","activities":[],
         "apps":[{"id":"call_1","serverName":"mobbin","toolName":"search_screens",
                  "title":"Screens","prefersBorder":true}]}
        """#.utf8))
        XCTAssertEqual(withApps.apps?.count, 1)
        XCTAssertEqual(withApps.apps?.first?.displayTitle, "Screens")
        XCTAssertEqual(withApps.apps?.first?.serverName, "mobbin")
        XCTAssertEqual(withApps.presentedText, "")

        let withoutApps = try JSONDecoder().decode(CantripRemoteMessage.self, from: Data(#"""
        {"id":"m2","role":"assistant","text":"Plain reply","thinking":"","activities":[]}
        """#.utf8))
        XCTAssertNil(withoutApps.apps)
        XCTAssertEqual(withoutApps.presentedText, "Plain reply")
    }

    func testPayloadDecodingSanitizesCSPAndPermissions() throws {
        let payload = try JSONDecoder().decode(MCPAppPayload.self, from: payloadData())
        XCTAssertEqual(payload.permissions, ["clipboardWrite"])
        XCTAssertEqual(payload.csp.connectDomains, ["https://api.example.com"])
        XCTAssertEqual(payload.csp.resourceDomains, ["https://cdn.example.com"])
        XCTAssertEqual(payload.csp.frameDomains, ["https://frames.example.com"])
        XCTAssertTrue(payload.csp.policy.contains("connect-src 'self' https://api.example.com"))
        XCTAssertFalse(payload.csp.policy.contains("javascript"))
        XCTAssertFalse(payload.csp.policy.contains("camera"))
        XCTAssertTrue(MCPAppDocument.viewHTML(payload).contains("Content-Security-Policy"))
    }

    func testHostInitializeAndToolDataReplay() throws {
        var delivered: [[String: Any]] = []
        let host = MCPAppHost(app: samplePayload(), environment: {
            var env = MCPAppHost.Environment()
            env.theme = "light"
            env.width = 390
            env.hostVersion = "9.9"
            return env
        }, deliver: { text in
            delivered.append(MCPAppJSON.object(text) ?? [:])
        }, openLink: { _ in true })
        host.serverRequest = { _, _, completion in completion(.success([:])) }
        host.sendMessage = { _, completion in completion(true) }
        host.updateModelContext = { _ in }

        host.receive(MCPAppJSON.text(["jsonrpc": "2.0", "id": 1, "method": "ui/initialize", "params": [:]]))
        let result = try XCTUnwrap(delivered.first?["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, MCPAppHost.protocolVersion)
        XCTAssertEqual((result["hostInfo"] as? [String: Any])?["name"] as? String, "Cantrip Agent")
        let context = try XCTUnwrap(result["hostContext"] as? [String: Any])
        XCTAssertEqual(context["platform"] as? String, "mobile")
        XCTAssertEqual(context["userAgent"] as? String, "Cantrip Agent/9.9")
        let dimensions = try XCTUnwrap(context["containerDimensions"] as? [String: Any])
        XCTAssertEqual(dimensions["maxHeight"] as? Double, 640)
        XCTAssertEqual((context["deviceCapabilities"] as? [String: Any])?["touch"] as? Bool, true)
        XCTAssertEqual((context["deviceCapabilities"] as? [String: Any])?["hover"] as? Bool, false)
        XCTAssertNotNil((result["hostCapabilities"] as? [String: Any])?["serverTools"])

        host.receive(MCPAppJSON.text(["jsonrpc": "2.0", "method": "ui/notifications/initialized", "params": [:]]))
        XCTAssertEqual(delivered.compactMap { $0["method"] as? String }, [
            "ui/notifications/tool-input", "ui/notifications/tool-result"
        ])
        host.receive(MCPAppJSON.text(["jsonrpc": "2.0", "method": "ui/notifications/initialized", "params": [:]]))
        XCTAssertEqual(delivered.compactMap { $0["method"] as? String }.count, 2)

        host.receive(MCPAppJSON.text(["jsonrpc": "2.0", "id": 2, "method": "ui/initialize", "params": [:]]))
        host.receive(MCPAppJSON.text(["jsonrpc": "2.0", "method": "ui/notifications/initialized", "params": [:]]))
        XCTAssertEqual(delivered.compactMap { $0["method"] as? String }.suffix(2), [
            "ui/notifications/tool-input", "ui/notifications/tool-result"
        ])
    }

    func testHostOpenLinkValidationUnknownMessageAndProxyMapping() throws {
        var delivered: [[String: Any]] = []
        var opened: URL?
        let host = MCPAppHost(app: samplePayload(), environment: { .init() }, deliver: { text in
            delivered.append(MCPAppJSON.object(text) ?? [:])
        }, openLink: { url in opened = url; return true })
        var approvedText: String?
        host.sendMessage = { text, completion in
            approvedText = text
            completion(false)
        }
        host.serverRequest = { method, _, completion in
            if method == "tools/list" {
                completion(.success(["tools": [["name": "search_screens"]]]))
            } else {
                completion(.failure(MCPAppRequestError.server("Proxy failed")))
            }
        }

        host.receive(MCPAppJSON.text(["jsonrpc": "2.0", "id": "bad", "method": "ui/open-link", "params": ["url": "ftp://example.com"]]))
        XCTAssertEqual(errorCode(delivered.last), -32602)
        let credentialURL = "https://" + "user" + ":" + "pass" + "@example.com"
        host.receive(MCPAppJSON.text(["jsonrpc": "2.0", "id": "creds", "method": "ui/open-link", "params": ["url": credentialURL]]))
        XCTAssertEqual(errorCode(delivered.last), -32602)
        host.receive(MCPAppJSON.text(["jsonrpc": "2.0", "id": "ok", "method": "ui/open-link", "params": ["url": "https://example.com/path"]]))
        XCTAssertEqual(opened?.absoluteString, "https://example.com/path")
        XCTAssertNotNil(delivered.last?["result"])

        host.receive(MCPAppJSON.text(["jsonrpc": "2.0", "id": 4, "method": "unknown/method", "params": [:]]))
        XCTAssertEqual(errorCode(delivered.last), -32601)

        host.receive(MCPAppJSON.text([
            "jsonrpc": "2.0", "id": 5, "method": "ui/message",
            "params": ["role": "user", "content": [["type": "text", "text": "  hi\u{200B}   there  \n \n  next  "]]]
        ]))
        XCTAssertEqual(approvedText, "hi there\n\nnext")
        XCTAssertEqual(errorCode(delivered.last), -32000)

        host.receive(MCPAppJSON.text(["jsonrpc": "2.0", "id": 6, "method": "tools/list", "params": [:]]))
        let tools = ((delivered.last?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools?.first?["name"] as? String, "search_screens")

        host.receive(MCPAppJSON.text(["jsonrpc": "2.0", "id": 7, "method": "resources/read", "params": ["uri": "file://x"]]))
        XCTAssertEqual(errorCode(delivered.last), -32000)
        XCTAssertEqual(errorMessage(delivered.last), "Proxy failed")
    }

    @MainActor
    func testAPIConstructsMCPAppEndpointRequests() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MCPAppRequestProtocol.self]
        let client = URLSession(configuration: configuration)
        let api = CantripRemoteAPI(transport: .remote(try XCTUnwrap(URL(string: "https://cantrip.example"))),
                                   token: "unit-token", urlSession: client)
        let sessionID = "session 1"
        let appID = "call/with space"
        let encodedBase = "/api/v1/sessions/session%201/apps/call%2Fwith%20space"
        var step = 0
        MCPAppRequestProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + "unit-token")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
                           [URLQueryItem(name: "history", value: "recent")])
            switch step {
            case 0:
                step += 1
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath, encodedBase)
                XCTAssertEqual(request.timeoutInterval, 20)
                return (200, try self.payloadData(id: appID))
            case 1:
                step += 1
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath, encodedBase + "/request")
                let body = try requestBody(request)
                XCTAssertEqual(body["method"] as? String, "tools/list")
                XCTAssertEqual((body["params"] as? [String: Any])?["cursor"] as? String, "abc")
                return (200, try JSONSerialization.data(withJSONObject: ["result": ["ok": true, "count": 2]]))
            case 2:
                step += 1
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath, encodedBase + "/message")
                XCTAssertEqual(try requestBody(request)["text"] as? String, "approved text")
                return (200, try JSONSerialization.data(withJSONObject: ["accepted": true, "text": "approved text"]))
            case 3:
                step += 1
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath, encodedBase + "/context")
                XCTAssertTrue(try requestBody(request)["text"] is NSNull)
                return (200, try JSONSerialization.data(withJSONObject: ["accepted": true]))
            default:
                XCTFail("Unexpected request: \(request)")
                return (500, Data())
            }
        }
        addTeardownBlock { @MainActor in
            client.invalidateAndCancel()
            MCPAppRequestProtocol.handler = nil
        }

        let payload = try await api.mcpAppPayload(sessionID: sessionID, appID: appID)
        XCTAssertEqual(payload.id, appID)
        let result = try await api.mcpAppServerRequest(sessionID: sessionID, appID: appID,
                                                       method: "tools/list", params: ["cursor": "abc"])
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["count"] as? Double, 2)
        let normalized = try await api.sendMCPAppMessage(sessionID: sessionID, appID: appID, text: "approved text")
        XCTAssertEqual(normalized, "approved text")
        try await api.updateMCPAppContext(sessionID: sessionID, appID: appID, text: nil)
        XCTAssertEqual(step, 4)
    }

    private func errorCode(_ message: [String: Any]?) -> Int? {
        ((message?["error"] as? [String: Any])?["code"] as? NSNumber)?.intValue
    }

    private func errorMessage(_ message: [String: Any]?) -> String? {
        (message?["error"] as? [String: Any])?["message"] as? String
    }
}

private func requestBody(_ request: URLRequest) throws -> [String: Any] {
    let data: Data
    if let body = request.httpBody {
        data = body
    } else if let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var bytes = [UInt8](repeating: 0, count: 1024)
        var buffer = Data()
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            guard count > 0 else { break }
            buffer.append(contentsOf: bytes.prefix(count))
        }
        data = buffer
    } else {
        data = Data()
    }
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
