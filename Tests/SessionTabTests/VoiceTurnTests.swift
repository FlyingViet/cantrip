import Foundation

extension SessionTabTests {
    @MainActor
    static func testVoiceTurns() async throws {
        testVoiceSpeech()
        testVoiceTurnTracker()
        try await testVoiceTurnAPI()
        print("Voice turns: speakable replies, Home reply tracking and the voice API passed")
    }

    static func testVoiceSpeech() {
        let reply = """
        ## Today
        You have **two** meetings:
        - Standup at [9:00](https://cal.example.com/1)
        - Lunch with `Sam` at noon

        | Time | What |
        |---|---|
        | 9 | Standup |

        ```swift
        print("hi")
        ```
        Details: https://example.com/x
        """
        let spoken = VoiceSpeech.spokenText(reply)
        precondition(spoken == "Today. You have two meetings: Standup at 9:00. Lunch with Sam at noon. "
                     + "There's a table on screen. The code is on screen. Details: the link on screen.", spoken)
        let long = String(repeating: "This is one sentence. ", count: 200)
        let cut = VoiceSpeech.spokenText(long, limit: 100)
        precondition(cut.hasSuffix("sentence. The rest is on screen.") && cut.count < 140, cut)
    }

    static func testVoiceTurnTracker() {
        func message(_ role: ChatMessage.Role, _ text: String) -> ChatMessage { ChatMessage(role: role, text: text) }
        let earlier = [message(.user, "old question"), message(.assistant, "old answer")]
        let waiting = VoiceTurnTracker.progress(messages: earlier, baseline: 2, prompt: "what's next",
                                                isStreaming: true, stillQueued: true)
        precondition(waiting == .init(status: .queued, reply: ""), "Not in the chat yet: queued")
        var chat = earlier + [message(.user, "what's next"), message(.assistant, "Checking")]
        let thinking = VoiceTurnTracker.progress(messages: chat, baseline: 2, prompt: "what's next",
                                                 isStreaming: true, stillQueued: false)
        precondition(thinking == .init(status: .thinking, reply: "Checking"))
        chat[3].text = "Your next meeting is at 3."
        let done = VoiceTurnTracker.progress(messages: chat, baseline: 2, prompt: "what's next",
                                             isStreaming: false, stillQueued: false)
        precondition(done == .init(status: .done, reply: "Your next meeting is at 3."))
        let followed = VoiceTurnTracker.progress(messages: chat + [message(.user, "another"), message(.assistant, "later")],
                                                 baseline: 2, prompt: "what's next", isStreaming: true, stillQueued: false)
        precondition(followed == .init(status: .done, reply: "Your next meeting is at 3."),
                     "The next message starting means this one is answered, and its reply isn't ours")
        let failed = VoiceTurnTracker.progress(messages: earlier + [message(.user, "what's next"), message(.error, "Limit reached")],
                                               baseline: 2, prompt: "what's next", isStreaming: false, stillQueued: false)
        precondition(failed == .init(status: .failed, reply: "", error: "Limit reached"))
        let old = VoiceTurnTracker.progress(messages: earlier, baseline: 0, prompt: "old question",
                                            isStreaming: false, stillQueued: false)
        precondition(old.status == .done, "The baseline bounds the search, not the reply")
    }

    @MainActor
    static func testVoiceTurnAPI() async throws {
        let manager = SessionManager()
        let server = RemoteControlServer(manager: manager, encodingQueue: DispatchQueue(label: "cantrip.test.voice"),
                                         requestLog: { _ in })
        let port = Int.random(in: 20_000...45_000)
        let token = UUID().uuidString
        server.start(port: port, token: token)
        defer { server.stop() }
        let home = ChatSession(id: UUID())
        var homeOn = true
        server.voiceTurns.home = { homeOn ? home : nil }
        server.voiceTurns.submit = { session, text in session.messages.append(ChatMessage(role: .user, text: text)) }
        server.transcribe = { clip, _ in
            let data = try Data(contentsOf: clip)
            precondition(clip.pathExtension == "m4a")
            return data == Data("silence".utf8) ? "" : "what's on my calendar"
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        let client = URLSession(configuration: configuration)
        defer { client.invalidateAndCancel() }
        try await Task.sleep(nanoseconds: 300_000_000)
        func call(_ method: String, _ path: String, type: String? = nil, body: Data? = nil,
                  authenticated: Bool = true) async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.httpMethod = method
            if authenticated { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            if let type { request.setValue(type, forHTTPHeaderField: "Content-Type") }
            request.httpBody = body
            let (data, response) = try await client.data(for: request)
            return ((response as! HTTPURLResponse).statusCode,
                    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
        }

        let (unsigned, _) = try await call("GET", "/api/v1/voice/config", authenticated: false)
        precondition(unsigned == 401, "The voice API needs the pairing token (or a watch's signature)")
        let (configStatus, config) = try await call("GET", "/api/v1/voice/config")
        precondition(configStatus == 200 && (config["home"] as? [String: Any])?["available"] as? Bool == true, "\(config)")

        let (created, body) = try await call("POST", "/api/v1/voice/turns", type: "audio/mp4", body: Data("clip".utf8))
        let turn = body["turn"] as? [String: Any] ?? [:]
        precondition(created == 202 && turn["transcript"] as? String == "what's on my calendar"
                     && turn["status"] as? String == "thinking", "\(created) \(body)")
        precondition(home.messages.last?.text == "what's on my calendar", "The words go to Home's chat")
        let id = turn["id"] as? String ?? ""

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            home.messages.append(ChatMessage(role: .assistant, text: "You have **two** meetings:\n- Standup at 9"))
        }
        let (polled, answer) = try await call("GET", "/api/v1/voice/turns/\(id)?wait=3")
        let finished = answer["turn"] as? [String: Any] ?? [:]
        precondition(polled == 200 && finished["status"] as? String == "done"
                     && finished["reply"] as? String == "You have **two** meetings:\n- Standup at 9"
                     && finished["spoken"] as? String == "You have two meetings: Standup at 9.", "\(answer)")

        let (typed, typedBody) = try await call("POST", "/api/v1/voice/turns", type: "application/json",
                                                body: Data(#"{"text":"remind me later"}"#.utf8))
        precondition(typed == 202 && (typedBody["turn"] as? [String: Any])?["transcript"] as? String == "remind me later")
        let (silent, silentBody) = try await call("POST", "/api/v1/voice/turns", type: "audio/mp4", body: Data("silence".utf8))
        precondition(silent == 422 && (silentBody["error"] as? String)?.contains("didn't catch") == true, "\(silentBody)")
        let (wrongType, _) = try await call("POST", "/api/v1/voice/turns", type: "text/plain", body: Data("hi".utf8))
        precondition(wrongType == 415)
        let (missing, _) = try await call("GET", "/api/v1/voice/turns/\(UUID().uuidString)")
        precondition(missing == 404)
        homeOn = false
        let (off, offBody) = try await call("POST", "/api/v1/voice/turns", type: "application/json",
                                            body: Data(#"{"text":"hello"}"#.utf8))
        precondition(off == 503 && (offBody["error"] as? String)?.contains("Home is off") == true, "\(offBody)")
    }
}
