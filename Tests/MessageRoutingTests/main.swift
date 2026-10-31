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
            if args.contains("--disable-slash-commands"), !args.contains("--safe-mode") {
                guard let modelIndex = args.firstIndex(of: "--model"),
                      args[modelIndex + 1] == "gemini-3.8-flash-medium",
                      let fmtIndex = args.firstIndex(of: "--output-format"),
                      args[fmtIndex + 1] == "text",
                      // Headless agy prints nothing after refusing a command, so routing denies them.
                      let settingsIndex = args.firstIndex(of: "--settings"),
                      args[settingsIndex + 1] == #"{"permissions":{"deny":["command(*)"]}}"#,
                      args[2].hasPrefix("Answer from the text below alone; don't use any tools.")
                else { exit(6) }
                let grouping = args[2].contains("You group queued chat messages")
                print(grouping
                    ? #"{"combine":[3],"confidence":0.9}"#
                    : #"{"intent":"context","confidence":0.99,"evidence":"The config lives in /config"}"#)
                return
            }
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
            let grouping = args[2].hasPrefix("You group queued chat messages")
            let event: [String: Any] = [
                "type": "assistant.message_delta",
                "data": ["messageId": "fixture", "deltaContent": grouping
                    ? #"{"combine":[3],"confidence":0.9}"#
                    : #"{"intent":"context","confidence":0.99,"evidence":"The config lives in /config"}"#],
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
                                                message: "stop the server", supportsInjection: true,
                                                supportsParallel: true).action == .queue,
                   "The policy follows semantic intent, not the word stop")
        }
        let sideQuestion = "While that runs, what's the weather tomorrow?"
        let parallel = MessageRoutingDecision(intent: .parallel, confidence: 0.9, evidence: "the weather tomorrow")
        let resolved = MessageRoutingPolicy.resolve(parallel, message: sideQuestion,
                                                    supportsInjection: true, supportsParallel: true)
        expect(resolved.action == .parallel && resolved.explanation.hasPrefix("Running in parallel"),
               "Independent requests run in a background agent when the tab can start one")
        expect(MessageRoutingPolicy.resolve(parallel, message: sideQuestion, supportsInjection: true).action == .queue,
               "Without background agents, a parallel request waits its turn")
        expect(MessageRoutingPolicy.resolve(parallel, message: sideQuestion, supportsInjection: false,
                                            supportsParallel: true).action == .queue,
               "Parallel delivery needs the live input channel")
        expect(MessageRoutingPolicy.resolve(.init(intent: .parallel, confidence: 0.7, evidence: "the weather tomorrow"),
                                            message: sideQuestion, supportsInjection: true,
                                            supportsParallel: true).action == .queue,
               "Uncertain parallel decisions queue")
        expect(MessageRoutingPolicy.resolve(.init(intent: .parallel, confidence: 1, evidence: "the README"),
                                            message: sideQuestion, supportsInjection: true,
                                            supportsParallel: true).action == .queue,
               "Parallel decisions must be grounded in the new message")
        let brief = MessageRoutingPolicy.parallelDelivery(sideQuestion)
        expect(brief.hasSuffix("\n\n" + sideQuestion) && brief.contains("`side-`"),
               "The agent brief names the side- prefix and ends with the user's exact words")
        expect((try? MessageRoutingDecision.parse(#"{"intent":"parallel","confidence":0.9,"evidence":"x"}"#))?.intent == .parallel,
               "The parallel intent decodes")
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

        try testQueueGroupingPolicy()

        // Models that fence the JSON or explain it afterwards still yield the object alone.
        let fenced = "```json\n{\"combine\":[3],\"confidence\":0.95}\n```\n\nMessages 1 and 3 {both} concern the button."
        expect(MessageRouter.jsonAnswer(fenced) == #"{"combine":[3],"confidence":0.95}"#, "Fenced answer is unwrapped")
        expect(MessageRouter.jsonAnswer(#"{"evidence":"a } in \"text\"","x":{"y":1}} trailing"#)
               == #"{"evidence":"a } in \"text\"","x":{"y":1}}"#, "Braces inside strings don't end the object")
        expect(MessageRouter.jsonAnswer("no json here") == "no json here", "Text without an object is left for the parser to reject")
        expect(MessageRouter.jsonAnswer("{\"open\":") == "{\"open\":", "An unterminated object is left for the parser to reject")

        let provider = MessageRouter.Provider.copilot(command: URL(fileURLWithPath: CommandLine.arguments[0]).path)
        let grouped = try await MessageRouter.groupQueue(
            QueueGroupingSnapshot(recentConversation: [], messages: [
                "Make the save button blue", "What's the weather?", "Also make it bigger",
            ]),
            provider: provider
        )
        expect(grouped == QueueGroupingDecision(combine: [3], confidence: 0.9),
               "Queue grouping uses the same isolated, tool-free CLI with its own instructions")
        let decision = try await MessageRouter.classify(snapshot("The config lives in /config"), provider: provider)
        expect(decision.intent == .context, "Isolated CLI returns a parsed decision")
        let agyProvider = MessageRouter.Provider.antigravity(
            command: URL(fileURLWithPath: CommandLine.arguments[0]).path,
            model: "gemini-3.8-flash-medium"
        )
        let agyDecision = try await MessageRouter.classify(snapshot("The config lives in /config"), provider: agyProvider)
        expect(agyDecision.intent == .context, "Antigravity CLI router returns a parsed decision using Gemini 3.8 Flash")
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
            try await liveQueueGrouping()
            let liveProvider: MessageRouter.Provider =
                ProcessInfo.processInfo.environment["CANTRIP_ROUTER_LIVE_PROVIDER"] == "claude"
                ? .claude(command: "claude") : .copilot(command: "copilot")
            for (text, expected) in [
                ("The config lives in /config", MessageRoutingDecision.Intent.context),
                ("After that, stop the server", .followUp),
                ("Stop the server", .parallel),
                ("While that runs, what's the weather forecast for Seattle tomorrow?", .parallel),
                ("Once the README is done, commit it and open a pull request", .followUp),
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
                case .parallel: action = .parallel
                case .correction, .replacement: action = .redirect
                case .cancellation: action = .cancel
                default: action = .queue
                }
                expect(MessageRoutingPolicy.resolve(result, message: text, supportsInjection: true,
                                                    supportsParallel: true).action == action,
                       "Live decisions must pass grounding and confidence gates, not just intent labels")
            }
        }
        // Allow process teardown and removal of isolated scratch directories.
        try await Task.sleep(nanoseconds: 2_500_000_000)
        if failures > 0 { exit(1) }
        print("Message routing tests passed")
    }

    private static func testQueueGroupingPolicy() throws {
        let texts = ["Make the save button blue", "!git status", "What's the weather?",
                     "Also make it bigger", "/deploy now", "[incident:abc] Investigate", ""]
        expect(QueueGroupingPolicy.candidateIndices(texts) == [0, 2, 3],
               "Commands, incidents and empty messages never join a combined turn")
        expect(QueueGroupingPolicy.candidateIndices(texts, excluded: [3]) == [0, 2],
               "Messages still being routed or delivered are left out")
        expect(QueueGroupingPolicy.candidateIndices(["!ls", "Also fix it"]).isEmpty,
               "A command at the front of the queue runs on its own")
        expect(QueueGroupingPolicy.candidateIndices(texts, excluded: [0]).isEmpty,
               "The next message itself must be eligible")
        expect(QueueGroupingPolicy.candidateIndices(Array(repeating: "Fix it", count: 20)).count
               == QueueGroupingPolicy.maxCandidates, "The router sees a bounded number of messages")
        expect(QueueGroupingPolicy.candidateIndices([String(repeating: "a", count: 6_001), "b"]).isEmpty,
               "Very large messages run alone")

        let candidates = ["Make the save button blue", "What's the weather?", "Also make it bigger"]
        expect(QueueGroupingPolicy.group(.init(combine: [3], confidence: 0.9), candidateTexts: candidates) == [0, 2],
               "A later related message is pulled forward past an unrelated one")
        expect(QueueGroupingPolicy.group(.init(combine: [3, 1, 3], confidence: 0.9), candidateTexts: candidates) == [0, 2],
               "Message 1 and duplicates are ignored")
        expect(QueueGroupingPolicy.group(.init(combine: [3], confidence: 0.7), candidateTexts: candidates) == [0],
               "Uncertain grouping runs messages one at a time")
        expect(QueueGroupingPolicy.group(.init(combine: [4], confidence: 1), candidateTexts: candidates) == [0],
               "Out-of-range numbers invalidate the whole decision")
        expect(QueueGroupingPolicy.group(.init(combine: [], confidence: 1), candidateTexts: candidates) == [0],
               "No related messages means the next one runs alone")
        let big = String(repeating: "x", count: 7_000)
        expect(QueueGroupingPolicy.group(.init(combine: [2, 3], confidence: 1),
                                         candidateTexts: [big, big, "short"]) == [0, 2],
               "Combined turns stay within the length bound")

        let prompt = QueueGroupingPolicy.combinedPrompt(["Make the save button blue", "Also make it bigger"])
        expect(prompt.hasPrefix("(Cantrip note, not from the user:")
               && prompt.contains("Message 1:\nMake the save button blue\n\nMessage 2:\nAlso make it bigger")
               && prompt.contains("these 2 related messages"),
               "The agent sees every message, numbered, with a note to handle them in one turn")

        expect((try? QueueGroupingDecision.parse(#"{"combine":[2,3],"confidence":0.8}"#))?.combine == [2, 3],
               "Grouping decisions decode")
        for invalid in ["[]", #"{"combine":[2]}"#, #"{"combine":[2],"confidence":2}"#,
                        #"{"combine":"2","confidence":0.9}"#] {
            expect((try? QueueGroupingDecision.parse(invalid)) == nil, "Malformed grouping decisions fail: \(invalid)")
        }
        let encoded = try QueueGroupingSnapshot(
            recentConversation: Array(repeating: .init(role: "user", text: big), count: 50),
            messages: Array(repeating: big, count: 50)
        ).encoded()
        expect(encoded.count < 20_000, "Grouping snapshot remains bounded")
        expect(encoded.contains(#""number":1"#) && encoded.contains(#""number":8"#) && !encoded.contains(#""number":9"#),
               "Messages are numbered from 1 for the router")
    }

    /// Real router: related follow-ups are grouped, unrelated requests are not.
    private static func liveQueueGrouping() async throws {
        let provider: MessageRouter.Provider =
            ProcessInfo.processInfo.environment["CANTRIP_ROUTER_LIVE_PROVIDER"] == "claude"
            ? .claude(command: "claude") : .copilot(command: "copilot")
        let conversation: [MessageRoutingSnapshot.Turn] = [
            .init(role: "user", text: "Add a Save button to the settings screen"),
            .init(role: "assistant", text: "Added a Save button to SettingsView.swift."),
        ]
        for (messages, expected) in [
            (["Make the save button blue", "What's the weather in Seattle tomorrow?",
              "Also make the save button a bit bigger"], [0, 2]),
            (["Fix the crash when tapping Save", "Then commit it and push"], [0, 1]),
            (["Rename the Save button to Apply", "What's a good recipe for dinner tonight?",
              "Book a flight to Denver for Friday"], [0]),
            (["Fix the login bug on the settings screen", "Deploy the current build to TestFlight",
              "Also add a unit test for that login fix"], [0, 2]),
            (["Update the README install steps", "Revert the last commit",
              "After the revert, redo the README change with the new wording"], [0]),
        ] {
            let raw = try await MessageRouter.completion(
                input: QueueGroupingSnapshot(recentConversation: conversation, messages: messages).encoded(),
                instructions: QueueGroupingPolicy.instructions, provider: provider
            )
            let decision = try QueueGroupingDecision.parse(raw)
            let group = QueueGroupingPolicy.group(decision, candidateTexts: messages)
            print("Live grouping: \(decision.combine) at \(decision.confidence) -> \(group)")
            expect(group == expected, "Live grouping for \(messages): expected \(expected), got \(group)")
        }
    }
}
