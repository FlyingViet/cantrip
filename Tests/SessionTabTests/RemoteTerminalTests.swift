import Foundation

extension SessionTabTests {
    /// Paired clients drive a tab's persistent shell through …/terminal: state carries between
    /// commands, polls return only new output, and Control-C, Clear and Private Local behave as on the Mac.
    @MainActor
    static func testRemoteTerminal() async throws {
        let manager = SessionManager()
        let server = RemoteControlServer(manager: manager)
        defer { withExtendedLifetime(manager) {} }
        let session = manager.newSession()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cantrip-terminal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("inner"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder); session.shell.restart() }
        session.workdir = folder.path
        let port = Int.random(in: 49152...65535), token = UUID().uuidString
        server.start(port: port, token: token)
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(250))
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        func call(_ method: String = "GET", _ suffix: String = "", query: String = "", _ body: [String: Any]? = nil,
                  authorized: Bool = true) async throws -> (Int, [String: Any]) {
            let url = "http://127.0.0.1:\(port)/api/v1/sessions/\(session.id.uuidString)/terminal\(suffix)\(query)"
            var request = URLRequest(url: URL(string: url)!)
            request.httpMethod = method
            if authorized { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
            let (data, response) = try await client.data(for: request)
            return ((response as! HTTPURLResponse).statusCode,
                    ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:])
        }
        /// Polls like a client until `done` holds for the output read so far.
        var output = "", end = 0, epoch = ""
        func poll(until done: (String, [String: Any]) -> Bool, _ what: String) async throws -> [String: Any] {
            for _ in 0..<100 {
                let (status, reply) = try await call(query: "?from=\(end)&epoch=\(epoch)")
                precondition(status == 200, "Polling the terminal: \(status) \(reply)")
                let text = reply["text"] as? String ?? ""
                output = reply["reset"] as? Bool == true ? text : output + text
                end = reply["end"] as? Int ?? end
                epoch = reply["epoch"] as? String ?? epoch
                if done(output, reply) { return reply }
                try await Task.sleep(for: .milliseconds(100))
            }
            preconditionFailure("Timed out waiting for \(what): \(output)")
        }

        func run(_ command: String) async throws {
            let reply = try await call("POST", "", ["command": command])
            precondition(reply.0 == 200, "Running \(command): \(reply)")
        }

        let anonymous = try await call(authorized: false)
        precondition(anonymous.0 == 401, "Pairing is required")
        let first = try await call()
        precondition(first.0 == 200 && first.1["reset"] as? Bool == true && first.1["workdir"] as? String == folder.path,
                     "The first read returns the whole terminal: \(first)")
        epoch = first.1["epoch"] as? String ?? ""
        end = first.1["end"] as? Int ?? 0
        let sessionReply = try await client.data(for: {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/sessions/\(session.id.uuidString)")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        }())
        let summary = (try JSONSerialization.jsonObject(with: sessionReply.0) as? [String: Any])?["session"] as? [String: Any]
        precondition(summary?["supportsTerminal"] as? Bool == true && summary?["terminalBusy"] as? Bool == false,
                     "Tabs advertise the terminal")

        try await run("cd inner && export CANTRIP_TERMINAL_TEST=kept")
        _ = try await poll(until: { _, reply in reply["isRunning"] as? Bool == false }, "the first command")
        let before = end
        try await run("pwd; echo \"$CANTRIP_TERMINAL_TEST\"")
        let after = try await poll(until: { text, reply in
            text.contains("kept") && reply["isRunning"] as? Bool == false
        }, "the second command")
        precondition(output.contains(folder.appendingPathComponent("inner").lastPathComponent),
                     "cd and exports persist between commands: \(output)")
        precondition(after["reset"] as? Bool == false && end > before, "Polls append only new output")
        precondition((after["history"] as? [String])?.last == "pwd; echo \"$CANTRIP_TERMINAL_TEST\"",
                     "History lists the commands for Up/Down")
        let unchanged = try await call(query: "?from=\(end)&epoch=\(epoch)")
        precondition(unchanged.1["text"] as? String == "" && unchanged.1["reset"] as? Bool == false,
                     "A caught-up poll is empty")

        let multiline = try await call("POST", "", ["command": "echo one\necho two"])
        let extra = try await call("POST", "", ["command": "ls", "workdir": "/"])
        let unknown = try await call("POST", "/explode", [String: Any]())
        precondition(multiline.0 == 400 && extra.0 == 400 && unknown.0 == 404, "Malformed requests are refused")

        try await run("sleep 30")
        _ = try await poll(until: { _, reply in reply["isRunning"] as? Bool == true }, "sleep to start")
        let interrupted = try await call("POST", "/interrupt")
        precondition(interrupted.0 == 200, "Control-C: \(interrupted)")
        _ = try await poll(until: { _, reply in reply["isRunning"] as? Bool == false }, "Control-C to stop sleep")

        let staleEpoch = epoch
        let cleared = try await call("POST", "/clear")
        precondition(cleared.0 == 200 && cleared.1["epoch"] as? String != staleEpoch && cleared.1["end"] as? Int == 0,
                     "Clear starts a new epoch: \(cleared)")
        let afterClear = try await call(query: "?from=\(end)&epoch=\(staleEpoch)")
        precondition(afterClear.1["reset"] as? Bool == true && afterClear.1["text"] as? String == "",
                     "A client from before Clear starts over")
        epoch = afterClear.1["epoch"] as? String ?? ""
        end = 0
        output = ""

        // Long output trims the front; a client whose place was trimmed gets the rest, reset.
        try await run("head -c 70000 /dev/zero | tr '\\0' a; echo")
        let staleEnd = end
        _ = try await poll(until: { _, reply in reply["isRunning"] as? Bool == false && (reply["end"] as? Int ?? 0) > 60_000 },
                           "long output")
        let trimmed = try await call(query: "?from=\(staleEnd)&epoch=\(epoch)")
        precondition(trimmed.1["reset"] as? Bool == true && (trimmed.1["start"] as? Int ?? 0) > 0
                     && (trimmed.1["text"] as? String ?? "").count < 60_000,
                     "A trimmed place resets to what the Mac kept")

        let privateLocal = ChatSession(id: ChatSession.privateLocalID)
        do {
            _ = try TabTerminalRemote.perform(nil, json: ["command": "ls"], session: privateLocal, from: nil, epoch: nil)
            preconditionFailure("Private Local has no terminal")
        } catch let error as TabTerminalError { precondition(error.status == 409) }
        precondition(!privateLocal.shell.isRunning && privateLocal.shell.output.isEmpty)
    }
}
