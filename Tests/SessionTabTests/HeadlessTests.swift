import CoreImage
import Foundation

extension SessionTabTests {
    @MainActor
    static func testHeadless() async throws {
        try testQRCodes()
        testPairingLinks()
        testTailscaleServeURL()
        try testRemoteTokenFile()
        try testHostLock()
        try await testHostControl()
        print("Headless host: QR codes, pairing links, Tailscale Serve, token file, host lock and CLI control passed")
    }

    /// Every size the pairing link can reach decodes with macOS's own QR reader.
    private static func testQRCodes() throws {
        func decode(_ code: QRCode) -> String? {
            let scale = 6, quiet = 4, side = (code.size + quiet * 2) * scale
            guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            context.setFillColor(gray: 0, alpha: 1)
            for y in 0..<code.size {
                for x in 0..<code.size where code.modules[y][x] {
                    context.fill(CGRect(x: (x + quiet) * scale, y: side - (y + quiet + 1) * scale, width: scale, height: scale))
                }
            }
            guard let image = context.makeImage() else { return nil }
            let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                      options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
            return (detector?.features(in: CIImage(cgImage: image)).first as? CIQRCodeFeature)?.messageString
        }
        let alphabet = Array("cantripagent://pair?v=1&name=mac-mini&token=AbC012_-%2B:/.")
        var versions = Set<Int>()
        for correction in [QRCode.ErrorCorrection.low, .medium, .quartile, .high] {
            for length in [1, 9, 17, 32, 55, 80, 120, 154, 190, 230, 300, 420] {
                let text = String((0..<length).map { alphabet[($0 * 7 + length) % alphabet.count] })
                guard let code = try? QRCode(text: text, correction: correction) else {
                    preconditionFailure("\(length) bytes should fit at \(correction)")
                }
                versions.insert(code.version)
                precondition(code.size == code.version * 4 + 17)
                precondition(decode(code) == text, "QR v\(code.version) \(correction) \(length) bytes did not decode")
            }
        }
        precondition(versions.contains(1) && versions.contains(where: { $0 >= 20 }), "Covered versions \(versions.sorted())")
        let link = CantripCLI.pairingLink(name: "mac-mini", token: String(repeating: "Ab3_-", count: 9).prefix(43).description,
                                          url: "https://mac-mini.example-tailnet.ts.net", direct: "192.168.0.10:8766")
        let pairing = try QRCode(text: link, correction: .low, maxVersion: 20)
        precondition(decode(pairing) == link)
        let lines = pairing.terminalLines(quietZone: 2, ansi: false)
        precondition(lines.count == (pairing.size + 5) / 2 && lines.allSatisfy { $0.count == pairing.size + 4 },
                     "Two module rows per terminal line, with the quiet zone")
        precondition(pairing.size + 4 + 2 <= 80, "The pairing code fits an 80-column terminal")
        do {
            _ = try QRCode(text: String(repeating: "x", count: 2_000), correction: .low, maxVersion: 20)
            preconditionFailure("Oversized text must fail")
        } catch QRCode.EncodingError.tooLong {}
    }

    private static func testPairingLinks() {
        let token = "a+b/c_d-" + String(repeating: "x", count: 35)
        let link = CantripCLI.pairingLink(name: "codespaces abc", token: token,
                                          url: "https://example-8765.app.github.dev", direct: nil)
        let components = URLComponents(string: link)!
        precondition(components.scheme == "cantripagent" && components.host == "pair")
        let items = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value ?? "") })
        precondition(items == ["v": "1", "name": "codespaces abc", "token": token,
                               "url": "https://example-8765.app.github.dev"], "\(items)")
        precondition(!link.contains("+"), "A plus must never be read back as a space: \(link)")
    }

    private static func testTailscaleServeURL() {
        let web: [String: Any] = [
            "mac-mini.example-tailnet.ts.net:443": ["Handlers": ["/": ["Proxy": "http://127.0.0.1:8765"]]],
            "mac-mini.example-tailnet.ts.net:8443": ["Handlers": ["/": ["Proxy": "http://localhost:8795"]]],
        ]
        precondition(Tailscale.serveURL(web: web, port: 8765) == "https://mac-mini.example-tailnet.ts.net")
        precondition(Tailscale.serveURL(web: web, port: 8795) == "https://mac-mini.example-tailnet.ts.net:8443")
        precondition(Tailscale.serveURL(web: web, port: 9999) == nil)
    }

    /// Runs only inside the temporary test home, so the Keychain is never touched.
    @MainActor
    private static func testRemoteTokenFile() throws {
        let url = RemoteTokenFile.url
        precondition(url.path.hasPrefix(ProcessInfo.processInfo.environment["CANTRIP_TAB_TEST_HOME"]! + "/"))
        try RemoteTokenFile.store("first-token")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Only this user may read the token")
        let folder = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        precondition((folder[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let loaded = try RemoteTokenFile.load()
        precondition(loaded == "first-token")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        do {
            _ = try RemoteTokenFile.load()
            preconditionFailure("A token others can read must be refused")
        } catch {}
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let settings = AppSettings.shared
        precondition(settings.ensureRemoteControlToken() == "first-token", "The app uses the file once it exists")
        let revision = settings.remoteControlCredentialRevision
        precondition(settings.regenerateRemoteControlToken())
        let rotated = try RemoteTokenFile.load()
        precondition(rotated != "first-token" && rotated?.count == 43 && settings.remoteControlCredentialRevision == revision + 1)
        precondition(settings.remoteControlToken == rotated)
    }

    private static func testHostLock() throws {
        precondition(HostLock.acquire(wait: 0))
        precondition(HostLock.holder()?.pid == getpid() && HostLock.holder()?.mode == "app")
        let other = open(HostLock.url.path, O_RDWR)
        defer { close(other) }
        precondition(flock(other, LOCK_EX | LOCK_NB) != 0, "A second host can't take the lock")
        HostLock.release()
        precondition(HostLock.holder() == nil, "The pid left in the file doesn't count once the lock is free")
        precondition(flock(other, LOCK_EX | LOCK_NB) == 0, "Released for an update's new build")
        flock(other, LOCK_UN)
        try testWindowLock()
    }

    /// One window app for the background engine: while one holds the lock, a second launch can't
    /// take it (it waits briefly for a quitting window, then gives up) and learns who holds it.
    private static func testWindowLock() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("window-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        precondition(WindowLock.holder(of: url) == nil, "no file, no window")
        let first = try requireHome(WindowLock.lock(url, wait: 0))
        precondition(first >= 0 && WindowLock.holder(of: url) == getpid())
        let started = Date()
        precondition(WindowLock.lock(url, wait: 0.3) == nil, "a second window app can't take the lock")
        precondition(Date().timeIntervalSince(started) >= 0.3, "it waits for a quitting window first")
        flock(first, LOCK_UN)
        close(first)
        precondition(WindowLock.holder(of: url) == nil, "the pid left in the file doesn't count once it's free")
        let next = try requireHome(WindowLock.lock(url, wait: 0))
        precondition(next >= 0 && WindowLock.holder(of: url) == getpid(), "the reopened window takes it")
        close(next)
    }

    /// `cantrip status|config|pair` through the real socket, as the terminal client sends them.
    @MainActor
    private static func testHostControl() async throws {
        let settings = AppSettings.shared
        let saved = (settings.copilotIdleReleaseMinutes, settings.copilotAllowSubagents, settings.remoteControlEnabled)
        defer {
            settings.copilotIdleReleaseMinutes = saved.0
            settings.copilotAllowSubagents = saved.1
            settings.remoteControlEnabled = saved.2
        }
        let manager = SessionManager()
        let control = HostControl(manager: manager)
        CLIServer.shared.controlHandler = { control.handle($0) }
        CLIServer.shared.start()
        try await waitForJournalTest {
            ((try? FileManager.default.attributesOfItem(atPath: CLIServer.socketPath))?[.posixPermissions] as? NSNumber)?
                .intValue == 0o600
        }
        func ask(_ object: [String: Any]) async throws -> [String: Any] {
            try await Task.detached { try CantripCLI.request(object) }.value
        }
        func refused(_ object: [String: Any]) async -> String? {
            do { _ = try await ask(object); return nil } catch let failure as CantripCLI.Failure { return failure.message }
            catch { return error.localizedDescription }
        }

        let status = try await ask(["command": "status"])
        precondition(status["host"] as? String == "app" && status["pid"] as? Int == Int(getpid())
                     && (status["tabs"] as? Int ?? 0) >= 1, "\(status)")

        let listed = try await ask(["command": "config"])["settings"] as? [String: Any] ?? [:]
        precondition(listed["copilotModel"] != nil && listed["remoteControlPort"] != nil && listed["copilotIdleReleaseMinutes"] != nil)
        let changed = try await ask(["command": "config", "set": ["copilotIdleReleaseMinutes": "45", "copilotAllowSubagents": "off"]])
        let values = changed["settings"] as? [String: Any] ?? [:]
        precondition(values["copilotIdleReleaseMinutes"] as? Int == 45 && values["copilotAllowSubagents"] as? Bool == false)
        precondition(settings.copilotIdleReleaseMinutes == 45 && !settings.copilotAllowSubagents)
        let savedBackend = settings.backend
        defer { settings.backend = savedBackend }
        let backend = try await ask(["command": "config", "set": ["backend": "claude"]])["settings"] as? [String: Any]
        precondition(backend?["backend"] as? String == BackendKind.claudeCode.rawValue && settings.backend == .claudeCode)
        let badBackend = await refused(["command": "config", "set": ["backend": "gpt"]])
        precondition(badBackend?.contains("copilot, claude") == true)
        let refusal1 = await refused(["command": "config", "set": ["remoteLANPort": "70000"]])
        precondition(refusal1?.contains("remoteLANPort") == true)
        let refusal2 = await refused(["command": "config", "set": ["cantripHomeEnabled": "maybe"]])
        precondition(refusal2?.contains("true or false") == true)
        let notANumber = await refused(["command": "config", "set": ["panelOpacity": "nan"]])
        precondition(notANumber?.contains("panelOpacity expects a number") == true, "NaN can't be saved or encoded")
        let refusal3 = await refused(["command": "config", "set": ["noSuchSetting": "1"]])
        precondition(refusal3?.contains("Unknown setting") == true)
        precondition(settings.copilotIdleReleaseMinutes == 45, "A rejected change leaves settings alone")

        settings.remoteControlEnabled = false
        let refusal4 = await refused(["command": "pair"])
        precondition(refusal4?.contains("Remote control is off") == true)
        settings.remoteControlEnabled = true
        let paired = try await ask(["command": "pair"])
        let token = try RemoteTokenFile.load()
        precondition(paired["token"] as? String == token && paired["tokenStore"] as? String == "file"
                     && !(paired["name"] as? String ?? "").isEmpty && paired["addresses"] is [String], "\(paired)")
        let rotated = try await ask(["command": "pair", "rotate": true])
        let stored = try RemoteTokenFile.load()
        precondition(rotated["token"] as? String != token && rotated["token"] as? String == stored)
        let refusal5 = await refused(["command": "dance"])
        precondition(refusal5?.contains("Unknown command") == true)
        try await testAppConnection(ask: ask, refused: refused, token: stored)
    }

    /// Cantrip.app as the background engine's client: only the engine hands out its connection,
    /// with the Mac notifications it queued for the app to post.
    @MainActor
    private static func testAppConnection(ask: ([String: Any]) async throws -> [String: Any],
                                          refused: ([String: Any]) async -> String?, token: String?) async throws {
        let notEngine = await refused(["command": "app-connection"])
        precondition(notEngine?.contains("isn't running its agents in the background") == true, "\(notEngine ?? "answered")")
        HostMode.isHeadless = true
        HostMode.isEngine = true
        defer {
            HostMode.isHeadless = false
            HostMode.isEngine = false
        }
        let first = try await ask(["command": "app-connection"])
        precondition(first["token"] as? String == token && first["port"] as? Int == AppSettings.shared.remoteControlPort
                     && first["localKey"] as? String == LocalClientKey.value && first["pid"] as? Int == Int(getpid())
                     && first["outbox"] as? String == MacNotices.outboxID && first["busy"] is Int, "\(first)")
        let status = try await ask(["command": "status"])
        precondition(status["host"] as? String == "engine")

        MacNotices.post(MacNotice(id: "n1", title: "Cantrip — Done", body: "All set", sessionID: "s1", runFinished: true))
        MacNotices.remove(["n0"])
        let start = first["seq"] as? Int ?? -1
        let sync = try await Task.detached { try BackgroundEngine.sync(after: start, outbox: MacNotices.outboxID) }.value
        precondition(sync.connection.token == token && sync.connection.localKey == LocalClientKey.value
                     && sync.seq == start + 2 && sync.notices.map(\.seq) == [start + 1, start + 2], "\(sync.notices)")
        guard case .post(let notice) = sync.notices[0].entry else { preconditionFailure("\(sync.notices[0])") }
        precondition(notice == MacNotice(id: "n1", title: "Cantrip — Done", body: "All set", sessionID: "s1", runFinished: true))
        precondition(sync.notices[1].entry == .remove(["n0"]))
        let caughtUp = try await Task.detached { try BackgroundEngine.sync(after: sync.seq, outbox: sync.outbox) }.value
        precondition(caughtUp.notices.isEmpty, "Only what's new since the app's last ask")
        let restarted = try await Task.detached { try BackgroundEngine.sync(after: 999, outbox: "an-earlier-engine") }.value
        precondition(restarted.notices.count == 2, "A cursor from an earlier engine starts over with the last few seconds")
    }
}
