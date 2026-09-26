import CryptoKit
import Foundation
import JavaScriptCore

extension SessionTabTests {
    @MainActor
    static func testRemoteDesktop() async throws {
        let suite = "desktop-test-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var date = Date()
        var access = (screen: true, control: true)
        let display = DesktopDisplay(id: 17, name: "Left screen", x: -1440, y: -120, width: 1440, height: 900)
        var displays = [display], captures = 0, posted: [DesktopCommand] = []
        var held: CheckedContinuation<Void, Never>?
        var holdCapture = false
        let desktop = RemoteDesktop(defaults: defaults, permission: { access }, listDisplays: { displays }, capture: { _ in
            captures += 1
            if holdCapture { await withCheckedContinuation { held = $0 } }
            return (Data("synthetic-pixels".utf8), 800, 500)
        }, post: { command, _ in posted.append(command) }, now: { date })
        defer { desktop.stop() }
        func rejected(_ action: () throws -> Void, status: Int) throws {
            do { try action(); preconditionFailure("Expected rejection") }
            catch let error as SessionModelSettingsError { precondition(error.status == status, error.message) }
        }
        try rejected({ _ = try desktop.start(control: false) }, status: 403)
        precondition(captures == 0 && posted.isEmpty)
        desktop.enabled = true
        access.screen = false
        try rejected({ _ = try desktop.start(control: false) }, status: 409)
        access.screen = true; access.control = false
        try rejected({ _ = try desktop.start(control: true) }, status: 409)
        let viewOnly = try desktop.start(control: false)
        let frame = try await desktop.frame(id: viewOnly.id, token: viewOnly.token, displayID: display.id)
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(base64Encoded: frame.encryptedJPEG)!),
            using: SymmetricKey(data: Data(base64Encoded: viewOnly.key)!),
            authenticating: frame.associatedData(leaseID: viewOnly.id))
        precondition(plain == Data("synthetic-pixels".utf8) && !frame.encryptedJPEG.contains("synthetic-pixels"))
        try rejected({ try desktop.input(id: viewOnly.id, token: viewOnly.token, sequence: 1, encrypted: "") }, status: 403)
        try desktop.stop(id: viewOnly.id, token: viewOnly.token)
        access.control = true
        let lease = try desktop.start(control: true)
        try rejected({ _ = try desktop.start(control: true) }, status: 409)
        try rejected({ try desktop.stop(id: lease.id, token: "wrong") }, status: 409)
        let captured = try await desktop.frame(id: lease.id, token: lease.token, displayID: display.id)
        func encrypted(_ command: DesktopCommand, sequence: Int) throws -> String {
            try AES.GCM.seal(JSONEncoder().encode(command), using: SymmetricKey(data: Data(base64Encoded: lease.key)!),
                authenticating: Data("cantrip-desktop|\(lease.id)|input|\(sequence)".utf8)).combined!.base64EncodedString()
        }
        let command = DesktopCommand(frameID: captured.id, kind: "text", text: "synthetic-private-input")
        let cipher = try encrypted(command, sequence: 2)
        try rejected({ try desktop.input(id: lease.id, token: lease.token, sequence: 2, encrypted: cipher) }, status: 409)
        try desktop.input(id: lease.id, token: lease.token, sequence: 1,
            encrypted: encrypted(.init(frameID: captured.id, kind: "click", x: 0.5, y: 0.5), sequence: 1))
        try desktop.input(id: lease.id, token: lease.token, sequence: 2, encrypted: cipher)
        precondition(posted.count == 2 && posted[1].text == command.text)
        try rejected({ try desktop.input(id: lease.id, token: lease.token, sequence: 2, encrypted: cipher) }, status: 409)
        try rejected({ try desktop.input(id: lease.id, token: lease.token, sequence: 3, encrypted: cipher) }, status: 400)
        var invalid = DesktopCommand(frameID: captured.id, kind: "click", x: -0.2, y: 0.5)
        try rejected({ try desktop.input(id: lease.id, token: lease.token, sequence: 3, encrypted: encrypted(invalid, sequence: 3)) }, status: 400)
        invalid.x = 0.5
        let point = RemoteDesktop.point(x: 0.5, y: 0.5, display: display)
        precondition(point.x == -720 && point.y == 330)
        date = date.addingTimeInterval(16)
        try rejected({ try desktop.input(id: lease.id, token: lease.token, sequence: 3, encrypted: encrypted(invalid, sequence: 3)) }, status: 409)
        precondition(posted.count == 2)
        let fresh = try await desktop.frame(id: lease.id, token: lease.token, displayID: display.id)
        displays = []
        try rejected({ try desktop.input(id: lease.id, token: lease.token, sequence: 3,
            encrypted: encrypted(.init(frameID: fresh.id, kind: "key", key: "return"), sequence: 3)) }, status: 409)
        displays = [display]
        desktop.enabled = false
        precondition(desktop.activeUntil == nil)
        try rejected({ try desktop.stop(id: lease.id, token: lease.token) }, status: 409)
        desktop.enabled = true
        let expiry = try desktop.start(control: false)
        date = date.addingTimeInterval(61)
        try rejected({ try desktop.stop(id: expiry.id, token: expiry.token) }, status: 409)
        let pending = try desktop.start(control: false)
        holdCapture = true
        let task = Task { try await desktop.frame(id: pending.id, token: pending.token, displayID: display.id) }
        try await waitForJournalTest { held != nil }
        desktop.stop()
        held?.resume(); held = nil
        do { _ = try await task.value; preconditionFailure("Late capture must not escape a stopped lease") }
        catch let error as SessionModelSettingsError { precondition(error.status == 409) }
        holdCapture = false
        try await testDesktopAPI(desktop)
        try testDesktopWeb()
        let attention = MacAttention()
        var alerts = 0, resolved = 0
        attention.onAttention = { _ in alerts += 1 }
        attention.onResolved = { _ in resolved += 1 }
        attention.record(.keychain); attention.record(.keychain)
        precondition(alerts == 1 && attention.issues.count == 1)
        attention.clear(.keychain)
        attention.record(.keychain)
        precondition(alerts == 2 && resolved == 1)
        let event = RemoteCompletion(id: UUID(), sessionID: UUID(), title: "sensitive-title", summary: "sensitive-detail",
                                    completedAt: Date(), kind: "macAttention", expiresAt: Date().addingTimeInterval(60))
        let registration = RemotePushRegistration(installationID: UUID(), serverID: UUID(),
            deviceToken: String(repeating: "a", count: 64), environment: "development", inputNeeded: true)
        let push = try RemoteNotifications.request(deliveryID: UUID(), completion: event, registration: registration,
                                                   fingerprint: "paired", authorization: "fixture")
        let payload = String(data: push.httpBody!, encoding: .utf8)!
        precondition(payload.contains("Mac needs attention") && payload.contains("macAttention") && !payload.contains("sensitive"))
        print("Mac access: opt-in, permissions, encrypted frames/input, expiry, replay, stale layout and API guards passed")
    }

    @MainActor
    private static func testDesktopAPI(_ desktop: RemoteDesktop) async throws {
        let manager = SessionManager()
        let server = RemoteControlServer(manager: manager, desktop: desktop)
        let port = Int.random(in: 49152...65535), token = UUID().uuidString
        server.start(port: port, token: token)
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(300))
        func request(_ path: String, auth: Bool = true, body: [String: Any]? = nil) async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/\(path)")!)
            request.httpMethod = body == nil ? "GET" : "POST"
            if auth { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            request.httpBody = try body.map { try JSONSerialization.data(withJSONObject: $0) }
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as! HTTPURLResponse).statusCode, try JSONSerialization.jsonObject(with: data) as! [String: Any])
        }
        let unauthorized = try await request("desktop/start", auth: false, body: ["control": false])
        precondition(unauthorized.0 == 401)
        let loaded = try await request("mac-access")
        precondition(loaded.0 == 200 && loaded.1["desktopEnabled"] as? Bool == true)
        let malformed = try await request("desktop/start", body: ["control": 1])
        precondition(malformed.0 == 400)
        let started = try await request("desktop/start", body: ["control": false])
        precondition(started.0 == 200 && started.1["key"] is String)
        let id = started.1["id"] as! String, leaseToken = started.1["token"] as! String
        let invalid = try await request("desktop/input", body: ["id": id, "token": leaseToken, "sequence": 1, "encrypted": "bogus"])
        precondition(invalid.0 == 403)
        let stopped = try await request("desktop/stop", body: ["id": id, "token": leaseToken])
        precondition(stopped.0 == 200)
        let pane = try await request("mac-access", body: ["permission": "arbitrary-url"])
        precondition(pane.0 == 400)
    }

    @MainActor
    private static func testDesktopWeb() throws {
        let source = try String(contentsOfFile: "Sources/Cantrip/RemoteControlServer.swift", encoding: .utf8)
        let start = source.range(of: "    let desktopState")!
        let end = source.range(of: "    function safeURL", range: start.upperBound..<source.endIndex)!
        let context = JSContext()!
        context.exceptionHandler = { _, error in fatalError(error!.toString()) }
        context.evaluateScript("""
        const elements={};const $=id=>elements[id]||(elements[id]={value:"1",checked:false,disabled:false,
          style:{},classList:{add(){},remove(){},toggle(){}},replaceChildren(){},append(){},showModal(){},close(){},addEventListener(){},removeAttribute(){}});
        const document={hidden:false,createElement(){return {}},addEventListener(){}};
        function addEventListener(){}let token="fixture",calls=[];
        const crypto={subtle:{}};function clearTimeout(){};function setTimeout(){return 1};
        function api(path,options){calls.push({path,body:options?JSON.parse(options.body):null});
          return Promise.resolve({name:"Mac",desktopEnabled:false,issues:[],permissions:[]})}
        \(source[start.lowerBound..<end.lowerBound])
        openDesktop();
        """)
        precondition(context.evaluateScript("calls.length===1 && calls[0].path==='/api/v1/mac-access' && calls[0].body===null")!.toBool())
        precondition(context.evaluateScript("$('desktopStart').disabled")!.toBool())
    }
}
