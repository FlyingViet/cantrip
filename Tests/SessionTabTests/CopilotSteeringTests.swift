import Foundation

private final class SteeringBackendFixture: Backend {
    var supportsMidTurnInjection = true
    var requests: [BackendRequest] = []
    var injections: [String] = []
    var replies: [(MidTurnDelivery) -> Void] = []
    var sink: ((BackendEvent) -> Void)?
    var cancellations = 0
    var beforeInjection: (() -> Void)?

    func send(_ request: BackendRequest, workdir: String, onEvent: @escaping (BackendEvent) -> Void) {
        requests.append(request)
        sink = onEvent
    }
    func injectMidTurn(_ text: String, completion: @escaping (MidTurnDelivery) -> Void) {
        beforeInjection?()
        injections.append(text)
        replies.append(completion)
    }
    func reply(_ result: MidTurnDelivery) { replies.removeFirst()(result) }
    func cancel() {
        cancellations += 1
        let pending = replies
        replies.removeAll()
        for reply in pending { reply(.uncertain("cancelled")) }
    }
    func reset() { cancel() }
}

private final class SteeringEvents {
    private let lock = NSLock()
    private var events: [BackendEvent] = []
    private var results: [MidTurnDelivery] = []
    func append(_ event: BackendEvent) { lock.withLock { events.append(event) } }
    func delivered(_ result: MidTurnDelivery) { lock.withLock { results.append(result) } }
    var text: String {
        lock.withLock { events.compactMap { if case .textDelta(let text) = $0 { return text }; return nil }.joined() }
    }
    var done: Int { lock.withLock { events.filter { if case .done = $0 { return true }; return false }.count } }
    var errors: [String] {
        lock.withLock { events.compactMap { if case .failure(let text) = $0 { return text }; return nil } }
    }
    var accepted: Int {
        lock.withLock { results.filter { if case .accepted = $0 { return true }; return false }.count }
    }
    var uncertain: Int {
        lock.withLock { results.filter { if case .uncertain = $0 { return true }; return false }.count }
    }
    var notSent: Int {
        lock.withLock { results.filter { if case .notSent = $0 { return true }; return false }.count }
    }
}

extension SessionTabTests {
    @MainActor
    static func testCopilotSteering() async throws {
        let settings = AppSettings.shared
        settings.backend = .copilot
        settings.memoryEnabled = false
        settings.voiceMode = false
        settings.attachScreen = false
        settings.shareLocation = false
        settings.shareCalendar = false
        settings.fileRAGEnabled = false

        let backend = SteeringBackendFixture()
        let chat = ChatSession(copilotBackend: backend)
        let journalURL = RunJournal.defaultDirectory.appendingPathComponent("\(chat.id.uuidString).jsonl")
        backend.beforeInjection = {
            let events = RunJournal.loadEvents(from: journalURL)
            precondition(events.last?.kind == .steeringDelivery && events.last?.status == "submitting")
            let recovered = RunJournal.recoveryState(from: events)!
            precondition(!recovered.queued.contains { $0.id == events.last?.queueItemID },
                         "a claimed context message cannot be replayed after a crash")
            precondition(recovered.activeRun!.messages.contains { $0.text == "Context one" },
                         "context must be durable before native delivery")
        }
        chat.submitRemote("Start the fixture")
        try await waitForJournalTest { backend.requests.count == 1 }
        let activity = ToolActivityFactory.start(id: "original-tool", toolName: "bash", arguments: ["command": "fixture"])
        backend.sink?(.activity(activity))
        try await waitForJournalTest { chat.currentActivity != nil }
        chat.submitRemote("Follow-up stays queued", mode: .queue)
        chat.selectionContext = SelectionContext(text: "Do not attach", appName: "Private")
        chat.submitRemote("Context one", mode: .inject)
        chat.submitRemote("Context two", mode: .inject)
        try await waitForJournalTest { backend.injections.count == 1 }
        precondition(backend.injections == ["Context one"] && chat.selectionContext != nil)
        backend.reply(.accepted(messageID: "native-one"))
        try await waitForJournalTest { backend.injections.count == 2 }
        precondition(backend.injections == ["Context one", "Context two"] && backend.cancellations == 0)
        backend.reply(.accepted(messageID: "native-two"))
        try await waitForJournalTest { chat.deliveryStatus?.contains("Context accepted") == true }
        backend.sink?(.activity(ToolActivityFactory.complete(activity, id: activity.id, success: true, output: "done")))
        try await waitForJournalTest { chat.currentActivity == nil }
        precondition(chat.messages.flatMap(\.activities).filter { $0.id == activity.id }.count == 1,
                     "tool completion after steering must update its original bubble")
        precondition(chat.queued.map(\.text) == ["Follow-up stays queued"])
        try await chat.flushJournal()
        let acknowledgements = RunJournal.loadEvents(from: journalURL).filter {
            $0.kind == .steeringDelivery && $0.status == "accepted"
        }
        precondition(acknowledgements.compactMap(\.nativeMessageID) == ["native-one", "native-two"])
        backend.sink?(.done)
        try await waitForJournalTest { backend.requests.count == 2 }
        precondition(backend.requests.last?.userMessage == "Follow-up stays queued")
        chat.cancel()

        for outcome in ["notSent", "uncertain", "cancel", "idle"] {
            let backend = SteeringBackendFixture()
            let chat = ChatSession(copilotBackend: backend)
            chat.submitRemote("Start \(outcome)")
            try await waitForJournalTest { backend.requests.count == 1 }
            chat.submitRemote("new constraint", mode: .inject)
            try await waitForJournalTest { backend.injections.count == 1 }
            switch outcome {
            case "notSent":
                backend.reply(.notSent)
                try await waitForJournalTest { chat.queued.count == 1 }
                precondition(chat.queued.first?.text == "new constraint")
            case "uncertain":
                backend.reply(.uncertain("acknowledgement lost"))
                try await waitForJournalTest { chat.deliveryStatus?.contains("uncertain") == true }
                backend.sink?(.done)
                try await waitForJournalTest { !chat.isStreaming }
                precondition(chat.queued.isEmpty && backend.requests.count == 1 && backend.injections.count == 1)
            case "cancel":
                let oldSink = backend.sink
                chat.cancel()
                chat.submitRemote("Successor")
                try await waitForJournalTest { backend.requests.count == 2 }
                oldSink?(.done)
                try await Task.sleep(for: .milliseconds(30))
                precondition(chat.isStreaming, "cancelled steering cannot complete a successor")
            default:
                backend.sink?(.done)
                try await Task.sleep(for: .milliseconds(30))
                precondition(chat.isStreaming, "idle must wait for the delivery outcome to be journaled")
                backend.reply(.accepted(messageID: "idle-race"))
                try await waitForJournalTest { !chat.isStreaming }
            }
            chat.cancel()
        }

        let unavailable = SteeringBackendFixture()
        unavailable.supportsMidTurnInjection = false
        let queued = ChatSession(copilotBackend: unavailable)
        queued.submitRemote("Start unsupported")
        try await waitForJournalTest { unavailable.requests.count == 1 }
        queued.submitRemote("keep me", mode: .inject)
        precondition(queued.queued.first?.text == "keep me" && unavailable.injections.isEmpty)
        queued.cancel()

        try await testSteeringDurabilityBarrier()
        try await testSteeringRecovery()
        try await testRemoteSteering()
        try await testCopilotBridge()
        print("Copilot steering: ordered delivery, durability, idle/cancel races, fallback and bridge passed")
    }

    @MainActor
    private static func testSteeringRecovery() async throws {
        let backend = SteeringBackendFixture()
        let chat = ChatSession(copilotBackend: backend)
        chat.submitRemote("Recover this task")
        try await waitForJournalTest { backend.requests.count == 1 }
        var step = ToolActivityFactory.start(
            id: "saved-step", toolName: "edit", arguments: ["path": "already-changed.swift"]
        )
        step.state = .succeeded
        backend.sink?(.activity(step))
        try await waitForJournalTest { !chat.messages.flatMap(\.activities).isEmpty }
        chat.submitRemote("RECOVERY_CONSTRAINT: preserve the public interface", mode: .inject)
        try await waitForJournalTest { backend.injections.count == 1 }
        backend.reply(.accepted(messageID: "recover-native"))
        try await waitForJournalTest { chat.deliveryStatus?.contains("Context accepted") == true }
        try await chat.flushJournal()
        let recovered = ChatSession(id: chat.id, copilotBackend: SteeringBackendFixture())
        precondition(recovered.canResume)
        precondition(recovered.messages.contains { $0.text.contains("RECOVERY_CONSTRAINT") })
        precondition(recovered.queued.isEmpty, "accepted steering cannot reappear in the recovered queue")
        backend.sink?(.failure("fixture disconnect"))
        try await waitForJournalTest { backend.requests.count == 2 }
        precondition(backend.requests[1].prompt.contains("RECOVERY_CONSTRAINT"))
        precondition(backend.requests[1].prompt.contains("already-changed.swift"))
        precondition(backend.injections.count == 1, "recovery must not replay a native injection")
        chat.cancel()
    }

    @MainActor
    private static func testRemoteSteering() async throws {
        let backend = SteeringBackendFixture()
        let chat = ChatSession(copilotBackend: backend)
        let manager = SessionManager()
        manager.sessions = [chat]
        let server = RemoteControlServer(manager: manager)
        let port = Int.random(in: 49152...65535), token = UUID().uuidString
        server.start(port: port, token: token)
        defer { server.stop(); chat.cancel() }
        try await Task.sleep(for: .milliseconds(300))
        chat.submitRemote("Remote steering fixture")
        try await waitForJournalTest { backend.requests.count == 1 }
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        let url = URL(string: "http://127.0.0.1:\(port)/api/v1/sessions/\(chat.id)/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"text":"remote context","mode":"inject"}"#.utf8)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await client.data(for: request)
        precondition((response as! HTTPURLResponse).statusCode == 202)
        try await waitForJournalTest { backend.injections == ["remote context"] }
        backend.reply(.accepted(messageID: "remote-native"))
        try await waitForJournalTest { chat.deliveryStatus?.contains("Context accepted") == true }
        var detail = URLRequest(url: url.deletingLastPathComponent())
        detail.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await client.data(for: detail)
        let snapshot = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["session"] as! [String: Any]
        precondition((snapshot["deliveryStatus"] as? String)?.contains("Context accepted") == true)
        precondition(snapshot["isStreaming"] as? Bool == true && backend.cancellations == 0)
    }

    @MainActor
    private static func testSteeringDurabilityBarrier() async throws {
        let backend = SteeringBackendFixture()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        var held = false
        let chat = ChatSession(copilotBackend: backend, makeJournal: { id in
            let url = RunJournal.defaultDirectory.appendingPathComponent("\(id.uuidString).jsonl")
            return try RunJournal(sessionID: id) { handle in
                if !held, RunJournal.loadEvents(from: url).last?.kind == .steeringDelivery {
                    held = true
                    entered.signal()
                    guard release.wait(timeout: .now() + 6) == .success else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
                try handle.synchronize()
            }
        })
        chat.submitRemote("Start durability fixture")
        try await waitForJournalTest { backend.requests.count == 1 }
        chat.submitRemote("durable constraint", mode: .inject)
        var reached = false
        try await waitForJournalTest {
            if !reached { reached = entered.wait(timeout: .now()) == .success }
            return reached
        }
        precondition(backend.injections.isEmpty)
        chat.cancel()
        release.signal()
        try await Task.sleep(for: .milliseconds(50))
        precondition(backend.injections.isEmpty, "Stop during fsync must prevent a late send")

        let brokenBackend = SteeringBackendFixture()
        let broken = ChatSession(copilotBackend: brokenBackend, makeJournal: { id in
            let url = RunJournal.defaultDirectory.appendingPathComponent("\(id.uuidString).jsonl")
            return try RunJournal(sessionID: id) { handle in
                if RunJournal.loadEvents(from: url).last?.kind == .steeringDelivery {
                    throw CocoaError(.fileWriteOutOfSpace)
                }
                try handle.synchronize()
            }
        })
        broken.submitRemote("Start failing journal")
        try await waitForJournalTest { brokenBackend.requests.count == 1 }
        broken.submitRemote("unsent constraint", mode: .inject)
        try await waitForJournalTest { broken.journalError != nil && broken.queued.count == 1 }
        precondition(brokenBackend.injections.isEmpty, "failed durability cannot dispatch steering")
        broken.cancel()
    }

    @MainActor
    private static func testCopilotBridge() async throws {
        let fakeSDK = #"""
        export const RuntimeConnection = { forStdio: options => options };
        export class CopilotClient {
          async start() {}
          async forceStop() {}
          async createSession(config) {
            if (!config.streaming || !config.enableConfigDiscovery || config.remoteSession !== 'off')
              throw Error('Missing session settings');
            if (config.availableTools?.length === 0) {
              if (config.onPermissionRequest({kind:'write'}).kind !== 'reject')
                throw Error('Read-only council must deny writes');
            }
            let count = 0;
            return {
              async abort() {},
              async send(options) {
                count++;
                if (options.prompt === 'rpc-error') throw Error('transport lost');
                config.onEvent({type:'assistant.message_delta',id:`e${count}`,
                  data:{messageId:`m${count}`,deltaContent:`${count}:${options.mode}:${options.prompt}\n`}});
                if (options.prompt.includes('finish')) config.onEvent({type:'session.idle',data:{}});
                return `native-${count}`;
              }
            };
          }
        }
        """#
        let sdkURL = "data:text/javascript;base64," + Data(fakeSDK.utf8).base64EncodedString()
        let discovery = "function resolveCopilotRuntime() { return {sdk: '\(sdkURL)', runtime: 'fixture'}; }"
        let script = CopilotSessionBridge.script.replacingOccurrences(
            of: CopilotRuntime.discoveryScript, with: discovery
        )
        let backend = CopilotBackend(bridgeScript: script)
        let other = CopilotBackend(bridgeScript: script)
        other.readOnly = true
        defer { backend.cancel(); other.cancel() }
        let first = SteeringEvents()
        backend.send(BackendRequest(prompt: "hold", userMessage: "hold", previousTurns: []),
                     workdir: NSHomeDirectory(), onEvent: first.append)
        try await waitForJournalTest { backend.supportsMidTurnInjection || !first.errors.isEmpty }
        precondition(first.errors.isEmpty, "\(first.errors)")
        backend.injectMidTurn("context", completion: first.delivered)
        backend.injectMidTurn("finish", completion: first.delivered)
        try await waitForJournalTest { first.done == 1 || !first.errors.isEmpty }
        precondition(first.accepted == 2 && first.done == 1 && first.errors.isEmpty)
        precondition(first.text.contains("2:immediate:context") && first.text.contains("3:immediate:finish"))
        precondition(!backend.supportsMidTurnInjection)
        let next = SteeringEvents()
        backend.send(BackendRequest(prompt: "finish", userMessage: "finish", previousTurns: [
            ConversationTurn(user: "OLD_HISTORY_MUST_NOT_REPEAT", assistant: "old")
        ]), workdir: NSHomeDirectory(), onEvent: next.append)
        try await waitForJournalTest { next.done == 1 || !next.errors.isEmpty }
        precondition(next.text == "4:enqueue:finish\n" || next.text.hasPrefix("4:enqueue:finish\n\n"),
                     "follow-ups must keep the native session without resending history: \(next.text)")
        precondition(!next.text.contains("OLD_HISTORY_MUST_NOT_REPEAT"))
        let isolated = SteeringEvents()
        other.send(BackendRequest(prompt: "hold", userMessage: "hold", previousTurns: []),
                   workdir: NSHomeDirectory(), onEvent: isolated.append)
        try await waitForJournalTest { other.supportsMidTurnInjection }
        precondition(isolated.text.hasPrefix("1:enqueue:hold"), "tabs must have isolated SDK sessions")
        other.injectMidTurn("rpc-error", completion: isolated.delivered)
        try await waitForJournalTest { isolated.uncertain == 1 }
        precondition(isolated.accepted == 0 && isolated.done == 0)
        backend.reset()
        let reset = SteeringEvents()
        backend.send(BackendRequest(prompt: "finish", userMessage: "finish", previousTurns: []),
                     workdir: NSHomeDirectory(), onEvent: reset.append)
        try await waitForJournalTest { reset.done == 1 || !reset.errors.isEmpty }
        precondition(reset.text.hasPrefix("1:enqueue:finish"), "reset must discard the native session")

        let lateDeliveryScript = #"""
        import { createInterface } from 'node:readline';
        const emit = object => console.log(JSON.stringify(object));
        createInterface({input:process.stdin}).on('line', line => {
          const command = JSON.parse(line);
          if (command.kind === 'start') emit({kind:'started',runID:command.runID});
          else {
            emit({kind:'done',runID:command.runID});
            setTimeout(() => emit({kind:'delivery',runID:command.runID,id:command.id,status:'notSent'}), 30);
          }
        });
        """#
        let lateBackend = CopilotBackend(bridgeScript: lateDeliveryScript)
        defer { lateBackend.cancel() }
        let late = SteeringEvents()
        lateBackend.send(BackendRequest(prompt: "hold", userMessage: "hold", previousTurns: []),
                         workdir: NSHomeDirectory(), onEvent: late.append)
        try await waitForJournalTest { lateBackend.supportsMidTurnInjection }
        lateBackend.injectMidTurn("too late", completion: late.delivered)
        try await waitForJournalTest { late.done == 1 }
        precondition(late.notSent == 1 && late.uncertain == 0,
                     "idle cannot discard a pending definitive not-sent acknowledgement")
    }

    @MainActor
    static func testCopilotLiveSteering() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cantrip-steering-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backend = CopilotBackend()
        backend.modelOverride = "gpt-5.4-mini"
        backend.readOnly = true
        defer { backend.cancel() }
        let first = SteeringEvents()
        backend.send(BackendRequest(
            prompt: "This is a tool-free integration test. Remember CANTRIP_NATIVE_MARKER_782. Write a numbered list of 150 short sentences about colors. Do not use tools.",
            userMessage: "Tool-free steering fixture", previousTurns: []
        ), workdir: directory.path, onEvent: first.append)
        let deadline = Date().addingTimeInterval(120)
        while (!backend.supportsMidTurnInjection || first.text.isEmpty)
                && first.errors.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        precondition(first.errors.isEmpty && backend.supportsMidTurnInjection, "\(first.errors)")
        backend.injectMidTurn("New context: remember STEERING_ACCEPTED_493. Stop the list at the next opportunity and reply with STEERING_ACCEPTED_493.",
                              completion: first.delivered)
        while first.done == 0 && first.errors.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        precondition(first.errors.isEmpty && first.done == 1 && first.accepted == 1, "\(first.errors)")
        precondition(first.text.contains("STEERING_ACCEPTED_493"), "the real runtime must consume the steering")
        let second = SteeringEvents()
        backend.send(BackendRequest(prompt: "Reply only with the two exact marker strings from our conversation.",
                                    userMessage: "Recall markers", previousTurns: []),
                     workdir: directory.path, onEvent: second.append)
        while second.done == 0 && second.errors.isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        precondition(second.errors.isEmpty && second.done == 1, "\(second.errors)")
        precondition(second.text.contains("CANTRIP_NATIVE_MARKER_782") && second.text.contains("STEERING_ACCEPTED_493"))
        print("Live Copilot: immediate context consumed; both markers retained in the same session")
    }
}
