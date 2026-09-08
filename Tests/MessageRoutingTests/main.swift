import Foundation

@main
struct MessageRoutingTests {
    private static var failures = 0

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            failures += 1
            fputs("FAIL: \(message)\n", stderr)
        }
    }

    private static func snapshot(_ message: String) -> MessageRoutingSnapshot {
        .init(
            message: message, currentTask: "Update the README installation instructions.",
            recentConversation: [.init(role: "user", text: "Update the README installation instructions.")],
            activity: "Editing README.md", pendingMessages: [], supportsInjection: true
        )
    }

    static func main() async {
        do {
            try await run()
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            exit(1)
        }
    }

    private static func run() async throws {
        // The same executable is a fake CLI to exercise real process isolation,
        // output collection, cancellation and deadlines without provider usage.
        if CommandLine.arguments.dropFirst().first == "-p" {
            let args = CommandLine.arguments
            guard args.contains("--available-tools="), args.contains("--disable-builtin-mcps"),
                  args.contains("--no-custom-instructions"), !args.contains("--allow-all-tools"),
                  let home = ProcessInfo.processInfo.environment["COPILOT_HOME"],
                  URL(fileURLWithPath: home).resolvingSymlinksInPath()
                    == URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath()
            else { exit(4) }
            let config = try JSONSerialization.jsonObject(
                with: Data(contentsOf: URL(fileURLWithPath: home).appendingPathComponent("settings.json"))
            ) as? [String: Any]
            guard config?["disableAllHooks"] as? Bool == true else { exit(5) }
            if args[2].contains("DELAY_FIXTURE") { try await Task.sleep(nanoseconds: 20_000_000_000) }
            if args[2].contains("FAIL_FIXTURE") { exit(7) }
            if args[2].contains("TOOLS_FIXTURE") {
                print(#"{"type":"tool.execution_start","data":{"toolCallId":"unexpected","toolName":"bash"}}"#)
            }
            let event: [String: Any] = [
                "type": "assistant.message_delta",
                "data": ["messageId": "fixture", "deltaContent":
                    #"{"intent":"context","confidence":0.99,"evidence":"The config lives in /config"}"#],
            ]
            print(String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self))
            return
        }

        let message = "Actually, don't edit it, just explain it"
        for intent in [MessageRoutingDecision.Intent.correction, .replacement, .cancellation] {
            let low = MessageRoutingDecision(intent: intent, confidence: 0.94, evidence: "don't edit it")
            expect(MessageRoutingPolicy.resolve(low, message: message, supportsInjection: true).action == .queue,
                   "Disruptive routing requires at least 0.95 confidence")
            let high = MessageRoutingDecision(intent: intent, confidence: 0.99, evidence: "don't edit it")
            expect(MessageRoutingPolicy.resolve(high, message: message, supportsInjection: true).action
                   == (intent == .cancellation ? .cancel : .redirect), "Confident changes of direction are honored")
            let ungrounded = MessageRoutingDecision(intent: intent, confidence: 1, evidence: "stop this task")
            expect(MessageRoutingPolicy.resolve(ungrounded, message: message, supportsInjection: true).action == .queue,
                   "Transcript-only evidence cannot interrupt")
        }
        let context = MessageRoutingDecision(intent: .context, confidence: 0.9, evidence: "config")
        expect(MessageRoutingPolicy.resolve(context, message: "The config lives elsewhere", supportsInjection: true).action == .inject,
               "Supported context uses live injection")
        expect(MessageRoutingPolicy.resolve(context, message: "The config lives elsewhere", supportsInjection: false).action == .queue,
               "Unsupported injection never becomes a redirect")
        for intent in [MessageRoutingDecision.Intent.followUp, .ambiguous] {
            expect(MessageRoutingPolicy.resolve(.init(intent: intent, confidence: 1, evidence: "stop"),
                                                message: "stop the server", supportsInjection: true).action == .queue,
                   "The policy follows semantic intent, not the word stop")
        }
        for invalid in [
            "not JSON", #"{"intent":"redirect","confidence":1,"evidence":"stop"}"#,
            #"{"intent":"context","confidence":1.1,"evidence":"config"}"#,
            #"{"intent":"context","confidence":0.9}"#,
            "```json\n{}\n```",
        ] {
            do { _ = try MessageRoutingDecision.parse(invalid); expect(false, "Malformed decisions must fail") }
            catch { }
        }
        expect(MessageRoutingPolicy.canApply(originalGeneration: 1, currentGeneration: 1,
            originalRevision: 2, currentRevision: 2, isStreaming: true, stillQueued: true),
               "Live snapshot applies to its own queued prompt")
        for values in [(2, 2, true, true), (1, 3, true, true), (1, 2, false, true), (1, 2, true, false)] {
            expect(!MessageRoutingPolicy.canApply(originalGeneration: 1, currentGeneration: values.0,
                originalRevision: 2, currentRevision: values.1, isStreaming: values.2, stillQueued: values.3),
                   "Superseded, completed, cancelled and removed work cannot be interrupted")
        }
        let huge = String(repeating: "a", count: 100_000)
        let bounded = MessageRoutingSnapshot(message: huge, currentTask: huge,
            recentConversation: Array(repeating: .init(role: "user", text: huge), count: 100),
            activity: huge, pendingMessages: Array(repeating: huge, count: 100), supportsInjection: false)
        let encoded = try bounded.encoded()
        expect(encoded.count < 19_000, "Snapshot remains bounded")
        let request = try MessageRouter.localRequest("fixture", baseURL: "http://127.0.0.1:1234/v1/",
                                                    model: "private-model", key: "test-key")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        expect(body["tools"] == nil, "Local router has no tool schema")
        expect(body["model"] as? String == "private-model", "Local inference stays on the configured model")
        expect(request.url?.path == "/v1/chat/completions", "Configured local endpoint is used")
        do {
            _ = try MessageRouter.localResponse(Data(#"{"choices":[{"message":{"content":"{}","tool_calls":[]}}]}"#.utf8))
            expect(false, "Tool calls must be rejected even alongside text")
        } catch { }

        let provider = MessageRouter.Provider.copilot(command: URL(fileURLWithPath: CommandLine.arguments[0]).path)
        let decision = try await MessageRouter.classify(snapshot("The config lives in /config"), provider: provider)
        expect(decision.intent == .context, "Isolated CLI returns a parsed decision")
        do {
            _ = try await MessageRouter.classify(snapshot("FAIL_FIXTURE"), provider: provider)
            expect(false, "Nonzero exit must surface")
        } catch MessageRoutingError.processFailed(7) { }
        do {
            _ = try await MessageRouter.classify(snapshot("TOOLS_FIXTURE"), provider: provider)
            expect(false, "Unexpected tool activity invalidates the decision")
        } catch MessageRoutingError.invalidResponse { }
        let task = Task { try await MessageRouter.classify(snapshot("DELAY_FIXTURE"), provider: provider) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do { _ = try await task.value; expect(false, "Cancelled classification must throw") }
        catch is CancellationError { }
        let start = Date()
        do {
            _ = try await MessageRouter.classify(snapshot("DELAY_FIXTURE"), provider: provider)
            expect(false, "Hung inference must time out")
        } catch MessageRoutingError.timeout { }
        expect(Date().timeIntervalSince(start) < 15, "Router has a bounded deadline")

        if ProcessInfo.processInfo.environment["CANTRIP_ROUTER_LIVE_TEST"] == "1" {
            let liveProvider: MessageRouter.Provider =
                ProcessInfo.processInfo.environment["CANTRIP_ROUTER_LIVE_PROVIDER"] == "claude"
                ? .claude(command: "claude") : .copilot(command: "copilot")
            for (text, expected) in [
                ("The config lives in /config", MessageRoutingDecision.Intent.context),
                ("After that, stop the server", .followUp),
                ("Stop the server", .followUp),
                ("Wait, you are editing the wrong repository. Use the other repo instead.", .correction),
                ("Actually, don't edit the README, just explain the installation", .replacement),
                ("Stop working on the README now. Cancel this task.", .cancellation),
            ] {
                let raw = try await MessageRouter.completion(snapshot(text), provider: liveProvider)
                let result: MessageRoutingDecision
                do { result = try MessageRoutingDecision.parse(raw) }
                catch {
                    fputs("Synthetic fixture output: \(raw)\n", stderr)
                    throw error
                }
                print("Live router: \(result.intent.rawValue), confidence \(result.confidence)")
                expect(result.intent == expected, "Semantic live fixture: \(expected.rawValue)")
                let action: MessageRoutingAction
                switch expected {
                case .context: action = .inject
                case .correction, .replacement: action = .redirect
                case .cancellation: action = .cancel
                default: action = .queue
                }
                expect(MessageRoutingPolicy.resolve(result, message: text, supportsInjection: true).action == action,
                       "Live decisions must pass grounding and confidence gates, not just intent labels")
            }
        }
        // Allow process teardown and removal of isolated scratch directories.
        try await Task.sleep(nanoseconds: 2_500_000_000)
        if failures > 0 { exit(1) }
        print("Message routing tests passed")
    }
}
