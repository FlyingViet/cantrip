import XCTest
@testable import Hermes

/// A tool runner that records calls and returns canned tools and outputs.
final class FakeToolRunner: DirectLocalToolRunning, @unchecked Sendable {
    private let lock = NSLock()
    var tools: [DirectLocalMCPTool]
    var outputs: [String: DirectLocalToolOutput] = [:]
    private(set) var calls: [(tool: String, arguments: [String: Any])] = []
    private(set) var listed = 0

    init(tools: [DirectLocalMCPTool]) { self.tools = tools }

    func tools(for server: DirectLocalMCPServer) async throws -> [DirectLocalMCPTool] {
        lock.withLock { listed += 1 }
        return tools
    }

    func call(_ tool: String, arguments: [String: Any], on server: DirectLocalMCPServer) async throws -> DirectLocalToolOutput {
        lock.withLock {
            calls.append((tool, arguments))
            return outputs[tool] ?? DirectLocalToolOutput(text: "\(tool) result")
        }
    }

    var calledTools: [String] { lock.withLock { calls.map(\.tool) } }
}

final class DirectLocalToolsTests: XCTestCase {
    private let model = "fixture-model:latest"
    private let notes = DirectLocalMCPServer(name: "notes", source: "~/.copilot/mcp-config.json", command: "/usr/bin/true")

    override func setUp() {
        super.setUp()
        DirectLocalStubProtocol.reset()
        DirectLocalStubProtocol.replies["/api/tags"] = DirectLocalStubProtocol.json(["models": [["name": model]]])
        DirectLocalStubProtocol.replies["/api/show"] = DirectLocalStubProtocol.json(["model_info": ["general.architecture": "x"]])
    }

    private func client() -> DirectLocalClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DirectLocalStubProtocol.self]
        return DirectLocalClient(configuration: configuration)
    }

    private func tempStore() -> DirectLocalStore {
        DirectLocalStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("direct-local-tools-\(UUID().uuidString)"),
            defaults: UserDefaults(suiteName: "direct-local-tools-\(UUID().uuidString)")!)
    }

    // MARK: Config files

    func testServersComeFromTheAgentConfigFiles() throws {
        let copilot = Data("""
        {"mcpServers": {
          "mail": {"type": "local", "command": "npx", "args": ["-y", "mail-mcp"], "tools": ["list", "get"]},
          "notes": {"command": "/opt/notes/bin/notes", "args": ["mcp"], "env": {"TOKEN": "secret"}, "tools": ["*"]},
          "web": {"type": "http", "url": "https://example.com/mcp"},
          "broken": {"type": "stdio"},
          "off": {"command": "x", "disabled": true}
        }}
        """.utf8)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let first = directory.appendingPathComponent("mcp-config.json")
        let second = directory.appendingPathComponent("claude.json")
        try copilot.write(to: first)
        try Data(#"{"mcpServers": {"mail": {"command": "other"}, "extra": {"command": "extra-mcp"}}, "projects": {}}"#.utf8)
            .write(to: second)
        let servers = DirectLocalMCPConfig.load(from: [first, second, directory.appendingPathComponent("missing.json")])
        XCTAssertEqual(servers.map(\.name), ["broken", "extra", "mail", "notes", "off", "web"])
        let mail = try XCTUnwrap(servers.first { $0.name == "mail" })
        XCTAssertEqual(mail.command, "npx", "the first file wins a name")
        XCTAssertEqual(mail.args, ["-y", "mail-mcp"])
        XCTAssertEqual(mail.allowedTools, ["list", "get"])
        XCTAssertTrue(mail.allows("list"))
        XCTAssertFalse(mail.allows("delete"), "the config's own tools list is respected")
        XCTAssertTrue(mail.isAvailable)
        let notes = try XCTUnwrap(servers.first { $0.name == "notes" })
        XCTAssertNil(notes.allowedTools, "* allows every tool")
        XCTAssertEqual(notes.env, ["TOKEN": "secret"])
        XCTAssertFalse(notes.fingerprint.contains("secret"), "the fingerprint never holds the environment")
        var changed = notes
        changed.env["TOKEN"] = "rotated"
        XCTAssertNotEqual(changed.fingerprint, notes.fingerprint, "changing how it starts reloads its tools")
        XCTAssertFalse(servers.first { $0.name == "web" }!.isAvailable, "remote servers aren't started")
        XCTAssertEqual(servers.first { $0.name == "web" }?.detail, "example.com · \(DirectLocalMCPConfig.displayPath(first))",
                       "a remote server shows its host, never the full URL")
        XCTAssertEqual(mail.detail, "npx -y mail-mcp · \(DirectLocalMCPConfig.displayPath(first))")
        XCTAssertFalse(servers.first { $0.name == "broken" }!.isAvailable)
        XCTAssertFalse(servers.first { $0.name == "off" }!.isAvailable)
        XCTAssertEqual(servers.first { $0.name == "extra" }?.source, DirectLocalMCPConfig.displayPath(second))
    }

    // MARK: Offering tools

    func testOfferedToolsRespectSettingsAndGetSafeUniqueNames() {
        let other = DirectLocalMCPServer(name: "mail box", source: "x", command: "/usr/bin/true", allowedTools: ["search", "read.message"])
        let catalog = [
            "notes": DirectLocalToolCatalogEntry(fingerprint: notes.fingerprint, tools: [
                DirectLocalMCPTool(name: "search", description: "Find notes",
                                   inputSchema: #"{"$schema":"http://json-schema.org/draft-07/schema#","type":"object","properties":{"q":{"type":"string"}}}"#),
                DirectLocalMCPTool(name: "delete", description: "Delete a note"),
                DirectLocalMCPTool(name: "peek", description: "", readOnly: true),
            ], loaded: Date()),
            "mail box": DirectLocalToolCatalogEntry(fingerprint: other.fingerprint, tools: [
                DirectLocalMCPTool(name: "search", description: "Find mail"),
                DirectLocalMCPTool(name: "read.message", description: "Read one"),
                DirectLocalMCPTool(name: "send", description: "Send mail"),
            ], loaded: Date()),
        ]
        var settings = DirectLocalToolSettings()
        XCTAssertTrue(DirectLocalTools.offered(servers: [notes, other], catalog: catalog, settings: settings).isEmpty,
                      "nothing is offered until a server is turned on")
        settings.setEnabled("notes", true)
        settings.setEnabled("mail box", true)
        settings.setEnabled("notes", "delete", false)
        settings.setAutomatic("mail box", "read.message", true)
        let offered = DirectLocalTools.offered(servers: [notes, other], catalog: catalog, settings: settings)
        XCTAssertEqual(offered.map(\.functionName), ["notes_search", "peek", "mail_box_search", "read_message"],
                       "colliding names get the server's prefix; unsafe characters become _; turned-off and disallowed tools are left out")
        XCTAssertEqual(offered.map(\.automatic), [false, true, false, true], "read-only and Run Automatically tools don't ask")
        let definition = offered[0].definition
        let function = definition["function"] as? [String: Any]
        XCTAssertEqual(definition["type"] as? String, "function")
        XCTAssertEqual(function?["description"] as? String, "Find notes")
        let parameters = function?["parameters"] as? [String: Any]
        XCTAssertNil(parameters?["$schema"])
        XCTAssertNotNil(parameters?["properties"])
        XCTAssertEqual((offered[1].definition["function"] as? [String: Any])?["description"] as? String, "peek",
                       "a tool without a description is described by its name")
        XCTAssertGreaterThan(DirectLocalTools.characters(offered), 100)
        XCTAssertEqual(DirectLocalTools.characters([]), 0)
        var stale = catalog
        stale["notes"]?.fingerprint = "old"
        XCTAssertFalse(DirectLocalTools.offered(servers: [notes, other], catalog: stale, settings: settings)
            .contains { $0.server.name == "notes" }, "a list from an older command isn't used")
        XCTAssertEqual(DirectLocalTools.functionName(String(repeating: "x", count: 80)).count, 64)
    }

    func testToolOutputsBecomeText() {
        let output = DirectLocalToolOutput(result: ["content": [
            ["type": "text", "text": "Hello"],
            ["type": "image", "data": "AAAA", "mimeType": "image/png"],
            ["type": "resource", "resource": ["uri": "file:///a.txt", "text": "file text"]],
            ["type": "resource_link", "name": "Doc", "uri": "https://example.com/doc"],
        ], "isError": true])
        XCTAssertEqual(output.text, "Hello\n[image (image/png) not shown: the local model only reads text.]\nfile text\n[Link: Doc https://example.com/doc]")
        XCTAssertTrue(output.isError)
        XCTAssertEqual(DirectLocalToolOutput(result: ["structuredContent": ["n": 1]]).text, #"{"n":1}"#)
        XCTAssertEqual(DirectLocalToolOutput(result: [:]).text, "(The tool returned nothing.)")
        XCTAssertEqual(DirectLocalTools.truncated("abcdef", limit: 3), "abc\n[Cut to 3 of 6 characters to fit the context window.]")
        XCTAssertEqual(DirectLocalTools.truncated("abc", limit: 3), "abc")
    }

    func testSettingsFromBeforeToolsStillLoad() throws {
        let old = Data(#"{"baseURL":"http://127.0.0.1:11234","model":"m","contextWindow":4096,"systemPrompt":"You are a helpful private assistant. Answer using only this conversation. You have no tools or internet access."}"#.utf8)
        let decoded = try JSONDecoder().decode(DirectLocalConfiguration.self, from: old)
        XCTAssertEqual(decoded.model, "m")
        XCTAssertEqual(decoded.contextWindow, 4096)
        XCTAssertEqual(decoded.tools, DirectLocalToolSettings(), "no tools until you turn them on")
        XCTAssertEqual(decoded.systemPrompt, DirectLocalConfiguration.defaultSystemPrompt,
                       "the old default that said there were no tools is upgraded")
        let custom = try JSONDecoder().decode(DirectLocalConfiguration.self, from: Data(#"{"model":"m","systemPrompt":"Be brief."}"#.utf8))
        XCTAssertEqual(custom.systemPrompt, "Be brief.", "your own prompt is kept")
        XCTAssertEqual(custom.baseURL, DirectLocalConfiguration.defaultBaseURL)
        var configuration = decoded
        configuration.tools.setEnabled("notes", true)
        configuration.tools.setAutomatic("notes", "search", true)
        let roundTrip = try JSONDecoder().decode(DirectLocalConfiguration.self, from: JSONEncoder().encode(configuration))
        XCTAssertEqual(roundTrip, configuration)
    }

    // MARK: Chat with tools

    @MainActor
    private func makeChat(store: DirectLocalStore, runner: FakeToolRunner, automatic: [String] = [],
                          contextWindow: Int = 8192) throws -> DirectLocalChat {
        var configuration = DirectLocalConfiguration(baseURL: "http://127.0.0.1:11434", model: model, contextWindow: contextWindow)
        configuration.tools.setEnabled("notes", true)
        automatic.forEach { configuration.tools.setAutomatic("notes", $0, true) }
        try store.saveConfiguration(configuration)
        let server = notes
        return DirectLocalChat(store: store, makeClient: { self.client() }, toolRunner: runner, loadServers: { [server] })
    }

    private func toolCall(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        ["message": ["role": "assistant", "content": "", "tool_calls": [["function": ["name": name, "arguments": arguments]]]],
         "done": false]
    }

    private let done: [String: Any] = ["message": ["role": "assistant", "content": ""], "done": true]

    @MainActor
    func testToolCallAsksFirstThenAnswersWithTheResult() async throws {
        let runner = FakeToolRunner(tools: [DirectLocalMCPTool(name: "search", description: "Find notes",
                                                               inputSchema: #"{"type":"object","properties":{"q":{"type":"string"}}}"#)])
        runner.outputs["search"] = DirectLocalToolOutput(text: "Note: buy milk")
        DirectLocalStubProtocol.queued["/api/chat"] = [
            DirectLocalStubProtocol.lines([["message": ["content": "Let me look."], "done": false], toolCall("search", ["q": "milk"]), done]),
            DirectLocalStubProtocol.lines([["message": ["content": "You need milk."], "done": false], done]),
        ]
        let store = tempStore()
        let chat = try makeChat(store: store, runner: runner)
        XCTAssertTrue(chat.send("What do I need?"))
        try await waitUntil { chat.awaitingApproval != nil }
        XCTAssertEqual(runner.listed, 1, "the server's tools were loaded before the first message")
        XCTAssertTrue(runner.calledTools.isEmpty, "nothing runs before you allow it")
        let waiting = try XCTUnwrap(chat.messages.last?.toolCalls.first)
        XCTAssertEqual(waiting.state, .waiting)
        XCTAssertEqual(waiting.label, "notes · search")
        XCTAssertEqual(waiting.arguments, #"{"q":"milk"}"#)
        let turn = MacDirectLocalView.turn(for: try XCTUnwrap(chat.messages.last), awaitingApproval: chat.awaitingApproval)
        XCTAssertEqual(turn.approval?.choices, ["once", "always", "deny"], "the transcript shows Allow Once / Always Allow / Deny")
        XCTAssertEqual(turn.tools.map(\.name), ["notes · search"])
        chat.respond(to: waiting.id, with: .once)
        try await waitUntil { !chat.isReplying }

        let reply = try XCTUnwrap(chat.messages.last)
        XCTAssertNil(reply.error)
        XCTAssertEqual(reply.content, "You need milk.")
        XCTAssertEqual(reply.toolRounds?.first?.content, "Let me look.")
        XCTAssertEqual(reply.displayText, "Let me look.\n\nYou need milk.")
        XCTAssertEqual(reply.toolCalls.map(\.state), [.done])
        XCTAssertEqual(reply.toolCalls.first?.result, "Note: buy milk")
        XCTAssertEqual(runner.calls.first?.arguments["q"] as? String, "milk")
        XCTAssertFalse(chat.configuration.tools.isAutomatic("notes", "search"), "Allow Once doesn't remember")

        let bodies = DirectLocalStubProtocol.sentBodies("/api/chat")
        XCTAssertEqual(bodies.count, 2)
        let tools = bodies[0]["tools"] as? [[String: Any]]
        XCTAssertEqual((tools?.first?["function"] as? [String: Any])?["name"] as? String, "search")
        let second = bodies[1]["messages"] as? [[String: Any]] ?? []
        XCTAssertEqual(second.map { $0["role"] as? String }, ["system", "user", "assistant", "tool"])
        XCTAssertTrue((second[0]["content"] as? String)?.contains(DirectLocalTools.systemNote) == true)
        XCTAssertEqual(second[3]["content"] as? String, "Note: buy milk")

        let relaunched = DirectLocalChat(store: store, makeClient: { self.client() }, toolRunner: runner, loadServers: { [] })
        XCTAssertEqual(relaunched.messages.last?.toolCalls.first?.result, "Note: buy milk", "tool steps are saved with the reply")
    }

    @MainActor
    func testDenyTellsTheModelAndAlwaysAllowRemembers() async throws {
        let runner = FakeToolRunner(tools: [DirectLocalMCPTool(name: "delete", description: "Delete"),
                                            DirectLocalMCPTool(name: "search", description: "Find")])
        DirectLocalStubProtocol.queued["/api/chat"] = [
            DirectLocalStubProtocol.lines([
                ["message": ["tool_calls": [["function": ["name": "delete", "arguments": ["id": 1]]],
                                            ["function": ["name": "search", "arguments": ["q": "a"]]],
                                            ["function": ["name": "made_up", "arguments": [:]]]]], "done": false], done]),
            DirectLocalStubProtocol.lines([["message": ["content": "Done."], "done": false], done]),
            DirectLocalStubProtocol.lines([toolCall("search", ["q": "b"]), done]),
            DirectLocalStubProtocol.lines([["message": ["content": "Again."], "done": false], done]),
        ]
        let store = tempStore()
        let chat = try makeChat(store: store, runner: runner)
        chat.send("Tidy up")
        try await waitUntil { chat.awaitingApproval != nil }
        let first = try XCTUnwrap(chat.awaitingApproval)
        chat.respond(to: first, with: .deny)
        try await waitUntil { chat.awaitingApproval != nil && chat.awaitingApproval != first }
        chat.respond(to: try XCTUnwrap(chat.awaitingApproval), with: .always)
        try await waitUntil { !chat.isReplying }
        let calls = chat.messages.last?.toolCalls ?? []
        XCTAssertEqual(calls.map(\.state), [.denied, .done, .failed])
        XCTAssertEqual(runner.calledTools, ["search"], "the denied tool never ran")
        XCTAssertTrue(calls[2].result?.contains("no tool named made_up") == true)
        XCTAssertTrue(chat.configuration.tools.isAutomatic("notes", "search"))
        XCTAssertTrue(store.loadConfiguration().tools.isAutomatic("notes", "search"), "Always Allow is saved")
        let toolMessages = (DirectLocalStubProtocol.sentBodies("/api/chat")[1]["messages"] as? [[String: Any]] ?? [])
            .filter { $0["role"] as? String == "tool" }
        XCTAssertTrue((toolMessages.first?["content"] as? String)?.contains("didn't allow") == true, "the model learns it was denied")

        chat.send("Again")
        try await waitUntil { !chat.isReplying }
        XCTAssertEqual(runner.calledTools, ["search", "search"], "an always-allowed tool runs without asking")
        XCTAssertEqual(chat.messages.last?.content, "Again.")
    }

    @MainActor
    func testStopWhileWaitingEndsTheReply() async throws {
        let runner = FakeToolRunner(tools: [DirectLocalMCPTool(name: "search", description: "Find")])
        DirectLocalStubProtocol.queued["/api/chat"] = [DirectLocalStubProtocol.lines([toolCall("search", ["q": "x"]), done])]
        let chat = try makeChat(store: tempStore(), runner: runner)
        chat.send("Find x")
        try await waitUntil { chat.awaitingApproval != nil }
        chat.stop()
        try await waitUntil { !chat.isReplying }
        XCTAssertEqual(chat.messages.last?.error, "Stopped.")
        XCTAssertEqual(chat.messages.last?.toolCalls.first?.state, .failed)
        XCTAssertNil(chat.awaitingApproval)
        XCTAssertTrue(runner.calledTools.isEmpty)
    }

    @MainActor
    func testTooManyToolsForTheContextIsRefusedBeforeSending() async throws {
        let schema = #"{"type":"object","properties":{"text":{"type":"string","description":"\#(String(repeating: "long ", count: 300))"}}}"#
        let runner = FakeToolRunner(tools: (0..<4).map { DirectLocalMCPTool(name: "tool\($0)", description: "Big", inputSchema: schema) })
        let chat = try makeChat(store: tempStore(), runner: runner, contextWindow: 1024)
        chat.send("Hi")
        try await waitUntil { !chat.isReplying }
        XCTAssertTrue(chat.messages.last?.error?.contains("Turn some tools off") == true, chat.messages.last?.error ?? "")
        XCTAssertTrue(DirectLocalStubProtocol.sentBodies("/api/chat").isEmpty, "nothing was sent to the model")
    }

    // MARK: A real stdio server

    func testHubStartsAStdioServerListsAndCallsToolsAndStopsWhenIdle() async throws {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("fake-mcp-\(UUID().uuidString).py")
        try Self.fakeServer.write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: script) }
        let server = DirectLocalMCPServer(name: "fake", source: "test", command: "/usr/bin/python3", args: [script.path],
                                          env: ["FAKE_GREETING": "hi from env"])
        let hub = DirectLocalMCPHub(idleTimeout: 0.5)
        let tools = try await hub.tools(for: server)
        XCTAssertEqual(tools.map(\.name), ["echo", "peek", "fail"], "both pages of tools/list")
        XCTAssertEqual(tools.map(\.readOnly), [false, true, false])
        XCTAssertTrue(tools[0].inputSchema.contains(#""properties""#))
        let echo = try await hub.call("echo", arguments: ["text": "hello"], on: server)
        XCTAssertEqual(echo, DirectLocalToolOutput(text: "echo: hello / hi from env"), "the configured environment reaches the server")
        let failed = try await hub.call("fail", arguments: [:], on: server)
        XCTAssertTrue(failed.isError)
        do {
            _ = try await hub.call("crash", arguments: [:], on: server)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("fake stopped"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("crashing on purpose"), "stderr explains it: \(error.localizedDescription)")
        }
        let again = try await hub.call("echo", arguments: ["text": "back"], on: server)
        XCTAssertEqual(again.text, "echo: back / hi from env", "a stopped server is started again")
        let deadline = Date().addingTimeInterval(10)
        while await !hub.runningServers.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        let running = await hub.runningServers
        XCTAssertTrue(running.isEmpty, "idle servers are stopped")
    }

    func testOneRoundOfBigResultsStillFitsWithTheQuestion() {
        let configuration = DirectLocalConfiguration(baseURL: "http://127.0.0.1:11434", model: model)  // 8,192 tokens
        let calls = (0..<5).map { index in
            DirectLocalToolCall(name: "get_message", server: "mail", tool: "get_message", arguments: #"{"id":\#(index)}"#,
                                state: .done, result: String(repeating: "\(index)", count: 8_000))
        }
        let conversation = [
            DirectLocalMessage(role: .user, content: "Summarize my last 5 emails"),
            DirectLocalMessage(role: .assistant, content: "", streaming: true,
                               toolRounds: [DirectLocalToolRound(content: "", calls: calls)]),
        ]
        let reserved = 2_000
        let messages = DirectLocalHistory.chatMessages(conversation, configuration: configuration, reservedCharacters: reserved)
        let total = messages.reduce(0) { $0 + (($1["content"] as? String)?.count ?? 0) }
        XCTAssertLessThanOrEqual(total + reserved, configuration.contextWindow * 3 + 600,
                                 "5 × 8,000 characters of results are shared out to fit the window")
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user", "assistant"] + Array(repeating: "tool", count: 5))
        XCTAssertEqual(messages[1]["content"] as? String, "Summarize my last 5 emails", "the question is always kept")
        let results = messages.filter { $0["role"] as? String == "tool" }.compactMap { $0["content"] as? String }
        XCTAssertTrue(results.allSatisfy { $0.contains("[Cut to") && $0.count > 1_000 }, "each result keeps a fair share")
    }

    func testStopDuringASlowStartReturnsAtOnceAndTheServerStillRegisters() async throws {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("slow-mcp-\(UUID().uuidString).py")
        try ("import time\n" + Self.fakeServer.replacingOccurrences(
            of: "    if method == \"initialize\":\n",
            with: "    if method == \"initialize\":\n        time.sleep(2)\n")).write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: script) }
        let server = DirectLocalMCPServer(name: "slow", source: "test", command: "/usr/bin/python3", args: [script.path])
        let hub = DirectLocalMCPHub(idleTimeout: 60)
        let task = Task { try await hub.tools(for: server) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let stopped = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected a cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(stopped), 1, "Stop doesn't wait for the server to start")
        let deadline = Date().addingTimeInterval(10)
        while await hub.runningServers.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        let running = await hub.runningServers
        XCTAssertEqual(running, ["slow"], "the start finished in the background and the idle reaper owns it")
        let tools = try await hub.tools(for: server)
        XCTAssertEqual(tools.count, 3, "the next use reuses it")
        await hub.stopAll()
    }

    func testMissingCommandIsExplained() async {
        let server = DirectLocalMCPServer(name: "ghost", source: "~/.copilot/mcp-config.json", command: "definitely-not-a-command-xyz")
        do {
            _ = try await DirectLocalMCPHub(idleTimeout: 1).tools(for: server)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Couldn't find"), error.localizedDescription)
        }
    }

    private static let fakeServer = #"""
    import json, os, sys
    def send(message):
        sys.stdout.write(json.dumps(message) + "\n"); sys.stdout.flush()
    for line in sys.stdin:
        message = json.loads(line)
        method, mid = message.get("method"), message.get("id")
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": 900, "method": "ping"})
            send({"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": message["params"]["protocolVersion"],
                  "capabilities": {"tools": {}}, "serverInfo": {"name": "fake", "version": "1"}}})
        elif method == "tools/list":
            if not message.get("params", {}).get("cursor"):
                send({"jsonrpc": "2.0", "id": mid, "result": {"nextCursor": "2", "tools": [
                    {"name": "echo", "description": "Echo text", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}}},
                    {"name": "peek", "description": "Look", "inputSchema": {"type": "object"}, "annotations": {"readOnlyHint": True}}]}})
            else:
                send({"jsonrpc": "2.0", "id": mid, "result": {"tools": [{"name": "fail", "inputSchema": {"type": "object"}}]}})
        elif method == "tools/call":
            name = message["params"]["name"]
            if name == "echo":
                text = message["params"]["arguments"]["text"] + " / " + os.environ.get("FAKE_GREETING", "")
                send({"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": "echo: " + text}]}})
            elif name == "crash":
                sys.stderr.write("crashing on purpose\n"); sys.stderr.flush(); sys.exit(3)
            else:
                send({"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": "nope"}], "isError": True}})
        elif mid is not None and method is None:
            pass
    """#

    private func waitUntil(timeout: TimeInterval = 10, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition() {
            if Date() > deadline { XCTFail("timed out"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
