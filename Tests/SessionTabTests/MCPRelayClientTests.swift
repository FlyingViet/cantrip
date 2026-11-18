import Foundation

extension SessionTabTests {
    /// The relay client resumes each wait exactly once and promptly: a doubled reply, a request or
    /// connection cancelled before it starts or while it waits, a timeout, closing with a request
    /// waiting, and a relay that isn't there.
    static func testRelayClientResumesOnce() async throws {
        final class FlakyUpstream: Upstream, @unchecked Sendable {
            let deliver: (Data) -> Void
            init(deliver: @escaping (Data) -> Void) { self.deliver = deliver }
            func send(_ message: Data, id: Any?) {
                guard let object = (try? JSONSerialization.jsonObject(with: message)) as? [String: Any], let id = object["id"] else { return }
                func reply(_ result: [String: Any]) {
                    deliver((try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])) ?? Data())
                }
                let name = (object["params"] as? [String: Any])?["name"] as? String
                switch (object["method"] as? String, name) {
                case ("tools/call", "silent"?): return
                case ("tools/call", "twice"?):
                    reply(["content": [["type": "text", "text": "first"]]])
                    reply(["content": [["type": "text", "text": "second"]]])
                case ("tools/call", _): reply(["content": [["type": "text", "text": "ok"]]])
                default: reply(["protocolVersion": "2025-03-26", "capabilities": [String: Any]()])
                }
            }
            func finishInput() {}
            func stop() {}
        }
        let socketPath = "/tmp/cantrip-rc-\(getpid()).sock"
        let relay = MCPRelay(environment: MCPRelay.Environment(
            server: { $0 == "flaky" ? MCPServer(name: "flaky", command: "built-in") : nil },
            builtIn: { _, deliver in FlakyUpstream(deliver: deliver) }), path: socketPath)
        relay.start()
        defer { relay.stop(); try? FileManager.default.removeItem(atPath: socketPath) }
        try await Task.sleep(for: .milliseconds(300))
        func connected() async throws -> MCPRelayClient {
            let client = MCPRelayClient(server: "flaky", tab: nil, backend: "test", path: socketPath)
            try await client.open(timeout: 5)
            return client
        }
        /// How the work ended and how long it took.
        func timed(_ work: @escaping @Sendable () async throws -> String,
                   cancelAfter: Duration? = nil, then: (@Sendable () -> Void)? = nil) async -> (String, Double) {
            let started = Date()
            let task = Task { try await work() }
            if let cancelAfter {
                try? await Task.sleep(for: cancelAfter)
                if let then { then() } else { task.cancel() }
            }
            let outcome: String
            switch await task.result {
            case .success(let text): outcome = text
            case .failure(let error): outcome = error is CancellationError ? "cancelled" : "failed: \(error.localizedDescription)"
            }
            return (outcome, Date().timeIntervalSince(started))
        }

        let client = try await connected()
        defer { client.close() }
        let twice = try await client.callTool("twice", arguments: [:], timeout: 5)
        let after = try await client.callTool("plain", arguments: [:], timeout: 5)
        precondition(twice.text == "first" && after.text == "ok", "a doubled reply answers once: \(twice) \(after)")

        let early = await timed {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.callTool("silent", arguments: [:], timeout: 10).text
        }
        precondition(early.0 == "cancelled" && early.1 < 2, "cancelled before it was sent: \(early)")
        let waiting = await timed({ try await client.callTool("silent", arguments: [:], timeout: 10).text }, cancelAfter: .milliseconds(200))
        precondition(waiting.0 == "cancelled" && waiting.1 < 2, "cancelled while waiting: \(waiting)")
        let slow = await timed { try await client.callTool("silent", arguments: [:], timeout: 0.5).text }
        precondition(slow.0.contains("didn't answer within") && slow.1 < 3, "timed out: \(slow)")

        let closing = try await connected()
        let closed = await timed({ try await closing.callTool("silent", arguments: [:], timeout: 10).text },
                                 cancelAfter: .milliseconds(200), then: { closing.close() })
        precondition(closed.0.contains("closed") && closed.1 < 2, "closed with a request waiting: \(closed)")
        let afterClose = await timed { try await closing.callTool("plain", arguments: [:], timeout: 10).text }
        precondition(afterClose.0.contains("closed") && afterClose.1 < 1, "a closed client refuses at once: \(afterClose)")

        let openEarly = await timed {
            withUnsafeCurrentTask { $0?.cancel() }
            try await MCPRelayClient(server: "flaky", tab: nil, backend: "test", path: socketPath).open(timeout: 10)
            return "opened"
        }
        precondition(openEarly.0 != "opened" && openEarly.1 < 2, "connecting when already cancelled: \(openEarly)")
        let nowhere = await timed {
            try await MCPRelayClient(server: "flaky", tab: nil, backend: "test", path: socketPath + ".missing").open(timeout: 10)
            return "opened"
        }
        precondition(nowhere.0.hasPrefix("failed") && nowhere.1 < 5, "no relay at that path: \(nowhere)")
        print("MCP relay client: doubled replies, cancelling, timeouts, closing and a missing relay each answer once passed")
    }
}
