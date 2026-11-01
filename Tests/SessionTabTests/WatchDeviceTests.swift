import CryptoKit
import Foundation

extension SessionTabTests {
    @MainActor
    static func testWatchDevices() async throws {
        testDeviceSignatureFormat()
        try testWatchDeviceRegistry()
        try await testWatchDeviceAPI()
        print("Apple Watch devices: signature format, registry, replay and stale-time checks and the API passed")
    }

    static func randomNonce() -> String {
        Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func deviceHeaders(method: String, target: String, body: Data, key: P256.Signing.PrivateKey, device: String,
                              time: Date = Date(), nonce: String = randomNonce()) -> [String: String] {
        let seconds = String(Int(time.timeIntervalSince1970))
        let message = DeviceSignature.canonical(method: method, target: target, time: seconds, nonce: nonce, body: body)
        let signature = try! key.signature(for: Data(message.utf8))
        return ["x-cantrip-device": device, "x-cantrip-time": seconds, "x-cantrip-nonce": nonce,
                "x-cantrip-signature": signature.derRepresentation.base64EncodedString()]
    }

    /// The format the watch app signs (its tests check the same vector).
    static func testDeviceSignatureFormat() {
        let body = Data(#"{"text":"hi"}"#.utf8)
        let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let canonical = DeviceSignature.canonical(method: "post", target: "/api/v1/voice/turns", time: "1793580000",
                                                  nonce: "bm9uY2Utbm9uY2UtMTY", body: body)
        precondition(canonical == "cantrip-device-v1\nPOST\n/api/v1/voice/turns\n1793580000\nbm9uY2Utbm9uY2UtMTY\n\(hash)", canonical)
        precondition(DeviceSignature.bodyHash(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    static func testWatchDeviceRegistry() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("watch-devices.json")
        let registry = WatchDeviceRegistry(file: file)
        let key = P256.Signing.PrivateKey()
        let publicKey = key.publicKey.x963Representation.base64EncodedString()
        do {
            _ = try registry.register(name: "Watch", publicKey: "bm90IGEga2V5")
            preconditionFailure("A key that isn't P-256 is refused")
        } catch WatchDeviceRegistry.Failure.invalidKey {}
        do {
            _ = try registry.register(name: String(repeating: "x", count: 61), publicKey: publicKey)
            preconditionFailure("A long name is refused")
        } catch WatchDeviceRegistry.Failure.invalidName {}
        let (device, created) = try registry.register(name: " Apple Watch ", publicKey: publicKey)
        precondition(created && device.name == "Apple Watch")
        let (again, createdAgain) = try registry.register(name: "Renamed Watch", publicKey: publicKey)
        precondition(!createdAgain && again.id == device.id && again.name == "Renamed Watch", "One entry per key")
        let saved = try String(contentsOf: file, encoding: .utf8)
        precondition(saved.contains(publicKey) && !saved.contains("privateKey"))
        let mode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue
        precondition(mode == 0o600, "The list is private to the user")
        precondition(WatchDeviceRegistry(file: file).all.map(\.id) == [device.id], "The list survives a relaunch")

        let target = "/api/v1/voice/turns/\(UUID().uuidString)?wait=20"
        let body = Data()
        let now = Date()
        let headers = deviceHeaders(method: "GET", target: target, body: body, key: key, device: device.id.uuidString, time: now)
        guard case .success(let signer) = registry.verify(method: "GET", target: target, headers: headers, body: body, now: now) else {
            preconditionFailure("A correctly signed request is accepted")
        }
        precondition(signer.id == device.id && registry.all.first?.lastUsedAt == now)
        precondition(registry.verify(method: "GET", target: target, headers: headers, body: body, now: now) == .failure(.replayed),
                     "A nonce works once")
        let fresh = deviceHeaders(method: "GET", target: target, body: body, key: key, device: device.id.uuidString, time: now)
        precondition(registry.verify(method: "GET", target: target + "0", headers: fresh, body: body, now: now) == .failure(.badSignature),
                     "Another target fails")
        precondition(registry.verify(method: "POST", target: target, headers: fresh, body: Data("x".utf8), now: now) == .failure(.badSignature),
                     "Another body or method fails")
        precondition(registry.verify(method: "GET", target: target, headers: fresh, body: body, now: now) != .failure(.replayed),
                     "A refused signature doesn't use up the nonce")
        let old = deviceHeaders(method: "GET", target: target, body: body, key: key, device: device.id.uuidString,
                                time: now.addingTimeInterval(-301))
        precondition(registry.verify(method: "GET", target: target, headers: old, body: body, now: now) == .failure(.staleTime))
        let stranger = deviceHeaders(method: "GET", target: target, body: body, key: P256.Signing.PrivateKey(), device: device.id.uuidString)
        precondition(registry.verify(method: "GET", target: target, headers: stranger, body: body) == .failure(.badSignature),
                     "Another key can't sign for this watch")
        let unknown = deviceHeaders(method: "GET", target: target, body: body, key: key, device: UUID().uuidString)
        precondition(registry.verify(method: "GET", target: target, headers: unknown, body: body) == .failure(.unknownDevice))
        precondition(registry.verify(method: "GET", target: target, headers: [:], body: body) == .failure(.missingHeaders))
        let didRemove = try registry.remove(device.id)
        precondition(didRemove && registry.all.isEmpty)
        let removed = deviceHeaders(method: "GET", target: target, body: body, key: key, device: device.id.uuidString)
        precondition(registry.verify(method: "GET", target: target, headers: removed, body: body) == .failure(.unknownDevice),
                     "A removed watch is cut off")
    }

    @MainActor
    static func testWatchDeviceAPI() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("watch-api-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let registry = WatchDeviceRegistry(file: folder.appendingPathComponent("watch-devices.json"))
        let server = RemoteControlServer(manager: SessionManager(), watchDevices: registry,
                                         encodingQueue: DispatchQueue(label: "cantrip.test.watch"), requestLog: { _ in })
        let port = Int.random(in: 20_000...45_000)
        let token = UUID().uuidString
        server.start(port: port, token: token)
        defer { server.stop() }
        let home = ChatSession(id: UUID())
        server.voiceTurns.home = { home }
        server.voiceTurns.submit = { session, text in session.messages.append(ChatMessage(role: .user, text: text)) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        let client = URLSession(configuration: configuration)
        defer { client.invalidateAndCancel() }
        try await Task.sleep(nanoseconds: 300_000_000)

        func call(_ method: String, _ target: String, json: Any? = nil, token useToken: Bool = false,
                  signer: (P256.Signing.PrivateKey, String)? = nil, headers fixed: [String: String]? = nil)
            async throws -> (Int, [String: Any], [String: String]) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(target)")!)
            request.httpMethod = method
            let body = try json.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
            if json != nil {
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            if useToken { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let signed = fixed ?? signer.map { deviceHeaders(method: method, target: target, body: body, key: $0.0, device: $0.1) } ?? [:]
            for (name, value) in signed { request.setValue(value, forHTTPHeaderField: name) }
            let (data, response) = try await client.data(for: request)
            return ((response as! HTTPURLResponse).statusCode,
                    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:], signed)
        }

        let key = P256.Signing.PrivateKey()
        let publicKey = key.publicKey.x963Representation.base64EncodedString()
        let (noToken, _, _) = try await call("POST", "/api/v1/watch/devices", json: ["name": "Apple Watch", "publicKey": publicKey])
        precondition(noToken == 401, "Registering needs the pairing token")
        let (added, addedBody, _) = try await call("POST", "/api/v1/watch/devices",
                                                   json: ["name": "Apple Watch", "publicKey": publicKey], token: true)
        let device = addedBody["device"] as? [String: Any] ?? [:]
        let id = device["id"] as? String ?? ""
        precondition(added == 201 && device["name"] as? String == "Apple Watch" && addedBody.keys.contains("internet")
                     && device["publicKey"] == nil, "\(addedBody)")
        let (readded, _, _) = try await call("POST", "/api/v1/watch/devices", json: ["name": "Apple Watch", "publicKey": publicKey], token: true)
        precondition(readded == 200, "The same key again is the same watch")
        let (bad, _, _) = try await call("POST", "/api/v1/watch/devices", json: ["name": "Apple Watch", "publicKey": "AAAA"], token: true)
        precondition(bad == 400)

        let (config, configBody, configHeaders) = try await call("GET", "/api/v1/voice/config", signer: (key, id))
        precondition(config == 200 && (configBody["home"] as? [String: Any])?["available"] as? Bool == true, "\(configBody)")
        let (replayed, replayBody, _) = try await call("GET", "/api/v1/voice/config", headers: configHeaders)
        precondition(replayed == 401 && (replayBody["error"] as? String)?.contains("already used") == true, "\(replayBody)")
        let (turn, turnBody, _) = try await call("POST", "/api/v1/voice/turns", json: ["text": "what time is it"], signer: (key, id))
        let turnID = (turnBody["turn"] as? [String: Any])?["id"] as? String ?? ""
        precondition(turn == 202 && home.messages.last?.text == "what time is it", "A signed text turn reaches Home: \(turnBody)")
        let (polled, _, _) = try await call("GET", "/api/v1/voice/turns/\(turnID)?wait=0", signer: (key, id))
        precondition(polled == 200, "The signature covers the query too")
        let (stranger, _, _) = try await call("GET", "/api/v1/voice/config", signer: (P256.Signing.PrivateKey(), id))
        precondition(stranger == 401)
        let (sessions, _, _) = try await call("GET", "/api/v1/sessions", signer: (key, id))
        precondition(sessions == 401, "A watch's signature opens only the voice API")
        let (devices, _, _) = try await call("GET", "/api/v1/watch/devices", signer: (key, id))
        precondition(devices == 401, "A watch can't list or add watches")
        let (vocabulary, _, _) = try await call("GET", "/api/v1/voice/vocabulary", signer: (key, id))
        precondition(vocabulary == 401, "…nor read the vocabulary")

        let (listed, listBody, _) = try await call("GET", "/api/v1/watch/devices", token: true)
        let entries = listBody["devices"] as? [[String: Any]] ?? []
        precondition(listed == 200 && entries.count == 1 && entries.first?["lastUsedAt"] is String, "\(listBody)")
        let (removed, _, _) = try await call("DELETE", "/api/v1/watch/devices/\(id)", token: true)
        precondition(removed == 200)
        let (cutOff, cutOffBody, _) = try await call("GET", "/api/v1/voice/config", signer: (key, id))
        precondition(cutOff == 401 && (cutOffBody["error"] as? String)?.contains("isn't set up") == true, "\(cutOffBody)")
        let (gone, _, _) = try await call("DELETE", "/api/v1/watch/devices/\(id)", token: true)
        precondition(gone == 404)
    }
}
