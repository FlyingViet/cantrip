import CryptoKit
import XCTest
@testable import CantripWatch

final class CantripDeviceSignatureTests: XCTestCase {
    func testCanonicalStringMatchesContractVector() {
        let body = Data(#"{"text":"hi"}"#.utf8)
        let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let expected = """
        cantrip-device-v1
        POST
        /api/v1/voice/turns
        1793580000
        bm9uY2Utbm9uY2UtMTY
        \(digest)
        """
        let canonical = CantripDeviceSignature.canonicalString(
            method: "POST", target: "/api/v1/voice/turns", time: "1793580000",
            nonce: "bm9uY2Utbm9uY2UtMTY", body: body
        )
        XCTAssertEqual(canonical, expected)
        XCTAssertFalse(canonical.hasSuffix("\n"))
        XCTAssertEqual(CantripDeviceSignature.bodyDigest(body), digest)
    }

    func testEmptyBodyDigest() {
        XCTAssertEqual(
            CantripDeviceSignature.bodyDigest(Data()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    func testMethodIsUppercasedAndQueryIsSigned() {
        let canonical = CantripDeviceSignature.canonicalString(
            method: "get", target: "/api/v1/voice/turns/ABC?wait=20", time: "1", nonce: "n", body: Data()
        )
        XCTAssertEqual(canonical.components(separatedBy: "\n")[1], "GET")
        XCTAssertEqual(canonical.components(separatedBy: "\n")[2], "/api/v1/voice/turns/ABC?wait=20")
    }

    func testHeadersSignAndVerifyWithSoftwareKey() throws {
        let key = P256.Signing.PrivateKey()
        let signer = SoftwareDeviceSigner(key: key)
        let body = Data(#"{"text":"hi"}"#.utf8)
        let date = Date(timeIntervalSince1970: 1_793_580_000.7)
        let headers = try CantripDeviceSignature.headers(
            deviceID: "6F1C2A4E-0000-4000-8000-000000000001", method: "POST", target: "/api/v1/voice/turns",
            body: body, date: date, nonce: "bm9uY2Utbm9uY2UtMTY", sign: { try signer.signature(for: $0) }
        )
        XCTAssertEqual(headers["X-Cantrip-Device"], "6F1C2A4E-0000-4000-8000-000000000001")
        XCTAssertEqual(headers["X-Cantrip-Time"], "1793580000")
        XCTAssertEqual(headers["X-Cantrip-Nonce"], "bm9uY2Utbm9uY2UtMTY")

        let signatureData = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(headers["X-Cantrip-Signature"])))
        let signature = try P256.Signing.ECDSASignature(derRepresentation: signatureData)
        let message = CantripDeviceSignature.canonicalString(
            method: "POST", target: "/api/v1/voice/turns", time: "1793580000",
            nonce: "bm9uY2Utbm9uY2UtMTY", body: body
        )
        let publicKey = try P256.Signing.PublicKey(x963Representation: signer.publicKeyX963)
        XCTAssertTrue(publicKey.isValidSignature(signature, for: Data(message.utf8)))
        XCTAssertFalse(publicKey.isValidSignature(signature, for: Data((message + "x").utf8)))
    }

    func testPublicKeyIsUncompressedX963Base64() throws {
        let signer = SoftwareDeviceSigner(key: P256.Signing.PrivateKey())
        let decoded = try XCTUnwrap(Data(base64Encoded: signer.publicKeyBase64))
        XCTAssertEqual(decoded.count, 65)
        XCTAssertEqual(decoded.first, 0x04)
    }

    func testNonceIsUnpaddedBase64URLOfAtLeast16Bytes() {
        let nonce = CantripDeviceSignature.makeNonce()
        XCTAssertNil(nonce.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
        let standard = nonce.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padded = standard + String(repeating: "=", count: (4 - standard.count % 4) % 4)
        XCTAssertGreaterThanOrEqual(Data(base64Encoded: padded)?.count ?? 0, 16)
        XCTAssertNotEqual(nonce, CantripDeviceSignature.makeNonce())
    }
}

final class CantripWatchProtocolTests: XCTestCase {
    func testTurnDecodesContractShape() throws {
        let json = Data("""
        {"turn": {"id": "0B8E6E3C-7A51-4C11-9A55-6B1F3B2C9D10", "status": "done",
         "transcript": "what's on my calendar", "reply": "**Two** meetings", "spoken": "Two meetings",
         "createdAt": "2026-11-01T19:00:00Z"}}
        """.utf8)
        let turn = try JSONDecoder().decode(CantripVoiceTurnEnvelope.self, from: json).turn
        XCTAssertEqual(turn.status, .done)
        XCTAssertTrue(turn.isFinished)
        XCTAssertEqual(turn.transcript, "what's on my calendar")
        XCTAssertEqual(turn.speakableText, "Two meetings")
    }

    func testUnknownStatusKeepsPollingAndReplyIsSpokenWithoutMarkdown() throws {
        let json = Data(#"{"turn": {"id": "A", "status": "transcribing", "reply": "**Hi** there"}}"#.utf8)
        let turn = try JSONDecoder().decode(CantripVoiceTurnEnvelope.self, from: json).turn
        XCTAssertEqual(turn.status, .thinking)
        XCTAssertFalse(turn.isFinished)
        XCTAssertEqual(turn.speakableText, "Hi there")
    }

    func testConfigDecodes() throws {
        let config = try JSONDecoder().decode(
            CantripVoiceConfig.self,
            from: Data(#"{"home": {"available": true}, "internet": "https://mac.example.ts.net:10000"}"#.utf8)
        )
        XCTAssertEqual(config.home?.available, true)
        XCTAssertEqual(CantripWatchURL.origin(config.internet)?.absoluteString, "https://mac.example.ts.net:10000")
        let off = try JSONDecoder().decode(CantripVoiceConfig.self, from: Data(#"{"home": {"available": false}, "internet": null}"#.utf8))
        XCTAssertNil(off.internet)
    }

    func testHTTPErrorsInPlainWords() {
        XCTAssertEqual(CantripWatchError.http(401, body: Data()), .unauthorized)
        XCTAssertEqual(CantripWatchError.http(422, body: Data(#"{"error": "Cantrip didn't catch that."}"#.utf8)), .noSpeech)
        XCTAssertEqual(CantripWatchError.http(503, body: Data()), .homeOff)
        XCTAssertEqual(CantripWatchError.http(500, body: Data(#"{"error": "Busy"}"#.utf8)).errorDescription, "Busy")
        XCTAssertEqual(CantripWatchError.noSpeech.errorDescription, "Didn't catch that. Try again.")
        XCTAssertEqual(CantripWatchError.unauthorized.errorDescription,
                       "This watch isn't set up anymore. Set it up again with your iPhone.")
        XCTAssertEqual(CantripWatchError.unreachable.errorDescription,
                       "Can't reach your Mac. Keep your iPhone nearby, or turn on the internet route in Cantrip on the Mac.")
    }

    func testRouteOrderPrefersTailnetThenLastWorking() throws {
        let tailnet = try XCTUnwrap(URL(string: "https://mac.example.ts.net"))
        let internet = try XCTUnwrap(URL(string: "https://mac.example.ts.net:10000"))
        XCTAssertEqual(CantripWatchRoute.order(tailnet: tailnet, internet: internet, lastWorking: nil).map(\.0),
                       [.tailnet, .internet])
        XCTAssertEqual(CantripWatchRoute.order(tailnet: tailnet, internet: internet, lastWorking: .internet).map(\.0),
                       [.internet, .tailnet])
        XCTAssertEqual(CantripWatchRoute.order(tailnet: tailnet, internet: nil, lastWorking: .internet).map(\.0),
                       [.tailnet])
    }

    func testURLsKeepTheSignedTargetExactly() throws {
        let base = try XCTUnwrap(CantripWatchURL.origin("https://Mac.Example.ts.net/"))
        XCTAssertEqual(base.absoluteString, "https://mac.example.ts.net")
        let target = try XCTUnwrap(CantripWatchURL.turnTarget(id: "0B8E6E3C-7A51-4C11-9A55-6B1F3B2C9D10", wait: 20))
        XCTAssertEqual(target, "/api/v1/voice/turns/0B8E6E3C-7A51-4C11-9A55-6B1F3B2C9D10?wait=20")
        XCTAssertEqual(CantripWatchURL.url(base: base, target: target)?.absoluteString, "https://mac.example.ts.net" + target)
        XCTAssertEqual(CantripWatchURL.turnTarget(id: "A", wait: 90), "/api/v1/voice/turns/A?wait=25")
        XCTAssertNil(CantripWatchURL.turnTarget(id: "../devices", wait: 0))
        let internet = try XCTUnwrap(CantripWatchURL.origin("https://mac.example.ts.net:10000"))
        XCTAssertEqual(CantripWatchURL.url(base: internet, target: "/api/v1/voice/config")?.absoluteString,
                       "https://mac.example.ts.net:10000/api/v1/voice/config")
    }

    func testOnlyHTTPSOriginsExceptLoopbackInDebug() {
        XCTAssertNil(CantripWatchURL.origin("http://mac.example.ts.net"))
        XCTAssertNil(CantripWatchURL.origin("https://user:pass@mac.example.ts.net"))
        XCTAssertNil(CantripWatchURL.origin(""))
        #if DEBUG
        XCTAssertEqual(CantripWatchURL.origin("http://127.0.0.1:8080")?.absoluteString, "http://127.0.0.1:8080")
        #endif
    }

    func testPlainTextStripsMarkdown() {
        let markdown = """
        # Today
        You have **two** meetings and a [doc](https://example.com) to read.
        - Standup at `9:30`
        * Review at *noon*

        ```
        code
        ```
        """
        XCTAssertEqual(CantripWatchText.plain(markdown), """
        Today
        You have two meetings and a doc to read.
        • Standup at 9:30
        • Review at noon
        """ + "\n\n" + "code")
    }
}

final class CantripSilenceDetectorTests: XCTestCase {
    func testStopsAfterPauseFollowingSpeech() {
        var detector = CantripSilenceDetector()
        var time: TimeInterval = 0
        func feed(_ level: Float, for seconds: TimeInterval) -> CantripSilenceDetector.Decision {
            var decision = CantripSilenceDetector.Decision.keepRecording
            let end = time + seconds
            while time < end - 0.0001, decision == .keepRecording {
                time += 0.1
                decision = detector.add(level: level, at: time)
            }
            return decision
        }
        XCTAssertEqual(feed(-55, for: 0.5), .keepRecording)
        XCTAssertEqual(feed(-20, for: 2), .keepRecording)
        XCTAssertTrue(detector.speechStarted)
        XCTAssertEqual(feed(-55, for: 1.3), .keepRecording)
        XCTAssertEqual(feed(-55, for: 0.4), .speechEnded)
    }

    func testLoudSpeechCountsEvenWhenItStartsAtOnce() {
        var detector = CantripSilenceDetector()
        var decision = CantripSilenceDetector.Decision.keepRecording
        for step in 1...5 { decision = detector.add(level: -22, at: Double(step) * 0.1) }
        XCTAssertEqual(decision, .keepRecording)
        XCTAssertTrue(detector.speechStarted)
    }

    func testGivesUpWithoutSpeechAndCapsLength() {
        var quiet = CantripSilenceDetector()
        var decision = CantripSilenceDetector.Decision.keepRecording
        var time: TimeInterval = 0
        while decision == .keepRecording, time < 20 {
            time += 0.1
            decision = quiet.add(level: -50, at: time)
        }
        XCTAssertEqual(decision, .noSpeech)
        XCTAssertEqual(time, 10, accuracy: 0.11)

        var talker = CantripSilenceDetector()
        XCTAssertEqual(talker.add(level: -10, at: 60), .maxDuration)
    }
}

final class WatchPhoneLinkReplyTests: XCTestCase {
    func testRegistrationReplyBecomesConfiguration() throws {
        let configuration = try WatchPhoneLink.configuration(from: [
            "deviceID": "6F1C2A4E-0000-4000-8000-000000000001",
            "tailnet": "https://mac.example.ts.net",
            "internet": "https://mac.example.ts.net:10000",
            "server": "Studio Mac",
        ])
        XCTAssertEqual(configuration.deviceID, "6F1C2A4E-0000-4000-8000-000000000001")
        XCTAssertEqual(configuration.tailnet.absoluteString, "https://mac.example.ts.net")
        XCTAssertEqual(configuration.internet?.absoluteString, "https://mac.example.ts.net:10000")
        XCTAssertEqual(configuration.serverName, "Studio Mac")
    }

    func testRegistrationErrorIsShownAsIs() {
        XCTAssertThrowsError(try WatchPhoneLink.configuration(from: ["error": "Pair Cantrip first."])) { error in
            XCTAssertEqual((error as? CantripWatchError)?.errorDescription, "Pair Cantrip first.")
        }
        XCTAssertThrowsError(try WatchPhoneLink.configuration(from: ["deviceID": "X", "tailnet": "http://mac.example"]))
    }
}

/// Stands in for the Mac: records each request and answers with `handler`.
private final class StubMac: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (URLRequest, Data) throws -> (Int, Data)
    private var recorded: [(URLRequest, Data)] = []

    init(_ handler: @escaping (URLRequest, Data) throws -> (Int, Data)) {
        self.handler = handler
    }

    var requests: [(URLRequest, Data)] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func answer(_ request: URLRequest) throws -> (Data, URLResponse) {
        lock.lock()
        let body = request.httpBody ?? Data()
        recorded.append((request, body))
        let handler = handler
        lock.unlock()
        let (status, data) = try handler(request, body)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: try XCTUnwrap(request.url), statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
        return (data, response)
    }
}

final class CantripWatchClientTests: XCTestCase {
    private let key = P256.Signing.PrivateKey()
    private let deviceID = "6F1C2A4E-0000-4000-8000-000000000001"

    override func setUp() {
        WatchSettings.lastRoute = nil
    }

    override func tearDown() {
        WatchSettings.lastRoute = nil
    }

    private func makeClient(_ mac: StubMac, internet: String? = nil) throws -> CantripWatchClient {
        CantripWatchClient(
            configuration: CantripWatchConfiguration(
                deviceID: deviceID,
                tailnet: try XCTUnwrap(URL(string: "https://mac.example.ts.net")),
                internet: internet.flatMap(URL.init(string:)),
                serverName: "Mac"
            ),
            signer: SoftwareDeviceSigner(key: key),
            transport: { try mac.answer($0) }
        )
    }

    private func assertSigned(_ request: URLRequest, body: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let url = try XCTUnwrap(request.url)
        let target = url.path + (url.query.map { "?\($0)" } ?? "")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Cantrip-Device"), deviceID, file: file, line: line)
        let time = try XCTUnwrap(request.value(forHTTPHeaderField: "X-Cantrip-Time"))
        XCTAssertLessThan(abs(Double(try XCTUnwrap(Int(time))) - Date().timeIntervalSince1970), 5, file: file, line: line)
        let nonce = try XCTUnwrap(request.value(forHTTPHeaderField: "X-Cantrip-Nonce"))
        let signature = try P256.Signing.ECDSASignature(derRepresentation: try XCTUnwrap(
            Data(base64Encoded: try XCTUnwrap(request.value(forHTTPHeaderField: "X-Cantrip-Signature")))
        ))
        let message = CantripDeviceSignature.canonicalString(
            method: try XCTUnwrap(request.httpMethod), target: target, time: time, nonce: nonce, body: body
        )
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: Data(message.utf8)), file: file, line: line)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), file: file, line: line)
    }

    func testTextTurnIsSignedAndFollowedUntilDone() async throws {
        let mac = StubMac { request, body in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/v1/voice/config"):
                return (200, Data(#"{"home": {"available": true}, "internet": "https://mac.example.ts.net:10000"}"#.utf8))
            case ("POST", "/api/v1/voice/turns"):
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
                XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: String], ["text": "what's next"])
                return (202, Data(#"{"turn": {"id": "T1", "status": "queued", "transcript": "what's next"}}"#.utf8))
            default:
                XCTAssertEqual(request.url?.query, "wait=20")
                return (200, Data(#"{"turn": {"id": "T1", "status": "done", "reply": "**Lunch**", "spoken": "Lunch"}}"#.utf8))
            }
        }
        let client = try makeClient(mac)
        let started = try await client.startTurn(text: "what's next")
        XCTAssertEqual(started.status, .queued)
        let final = try await client.follow(started, until: Date().addingTimeInterval(25))
        XCTAssertEqual(final.speakableText, "Lunch")
        XCTAssertEqual(mac.requests.map { $0.0.url?.path }, [
            "/api/v1/voice/config", "/api/v1/voice/turns", "/api/v1/voice/turns/T1",
        ])
        for (request, body) in mac.requests { try assertSigned(request, body: body) }
        XCTAssertEqual(WatchSettings.lastRoute, .tailnet)
    }

    func testFallsBackToTheInternetRouteAndRemembersIt() async throws {
        let mac = StubMac { request, _ in
            guard request.url?.port == 10000 else { throw URLError(.cannotConnectToHost) }
            if request.url?.path == "/api/v1/voice/config" {
                return (200, Data(#"{"home": {"available": true}, "internet": "https://mac.example.ts.net:10000"}"#.utf8))
            }
            return (202, Data(#"{"turn": {"id": "T2", "status": "thinking"}}"#.utf8))
        }
        let client = try makeClient(mac, internet: "https://mac.example.ts.net:10000")
        let audio = Data(repeating: 7, count: 1000)
        _ = try await client.startTurn(audio: audio)
        XCTAssertEqual(WatchSettings.lastRoute, .internet)
        let upload = try XCTUnwrap(mac.requests.last { $0.0.httpMethod == "POST" })
        XCTAssertEqual(upload.0.url?.absoluteString, "https://mac.example.ts.net:10000/api/v1/voice/turns")
        XCTAssertEqual(upload.0.value(forHTTPHeaderField: "Content-Type"), "audio/mp4")
        XCTAssertEqual(upload.1, audio)
        try assertSigned(upload.0, body: upload.1)
    }

    func testUnreachableMacAndHomeOffInPlainWords() async throws {
        let offline = StubMac { _, _ in throw URLError(.cannotConnectToHost) }
        do {
            _ = try await makeClient(offline).startTurn(text: "hi")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? CantripWatchError, .unreachable)
        }

        let homeOff = StubMac { _, _ in (200, Data(#"{"home": {"available": false}, "internet": null}"#.utf8)) }
        do {
            _ = try await makeClient(homeOff).startTurn(text: "hi")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? CantripWatchError, .homeOff)
        }
        XCTAssertFalse(homeOff.requests.contains { $0.0.httpMethod == "POST" })
    }

    func testRejectedDeviceAndNoSpeech() async throws {
        let noSpeech = StubMac { request, _ in
            request.httpMethod == "GET" ? (200, Data(#"{"home": {"available": true}}"#.utf8))
                : (422, Data(#"{"error": "Cantrip didn't catch that."}"#.utf8))
        }
        do {
            _ = try await makeClient(noSpeech).startTurn(audio: Data([1, 2, 3]))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? CantripWatchError, .noSpeech)
        }
        let removed = StubMac { _, _ in (401, Data()) }
        do {
            _ = try await makeClient(removed).turn(id: "T1", wait: 0)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? CantripWatchError, .unauthorized)
        }
    }
}
