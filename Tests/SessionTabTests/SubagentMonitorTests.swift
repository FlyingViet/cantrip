import AppKit
import Foundation
import SwiftUI
import WebKit

@MainActor
private final class SubagentPageDelegate: NSObject, WKNavigationDelegate {
    var finished = false
    var error: Error?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = error
    }
}

extension SessionTabTests {
    /// A fake SDK whose `spawn` prompt starts a background subagent that runs until
    /// stopped. Like Copilot CLI 1.0.88, the stop's completion report arrives only
    /// after the root session is idle, so the bridge must say so first.
    private static let subagentFakeSDK = #"""
    export const RuntimeConnection = { forStdio: options => options };
    export class CopilotClient {
      constructor() {}
      async start() {}
      async forceStop() {}
      async createSession(config) {
        const emit = event => config.onEvent({ id: `e${Math.random()}`, timestamp: new Date().toISOString(), ...event });
        const running = new Set();
        let late = false;
        const tasks = {
          async list() {
            return { tasks: [...[...running].map(id => ({ id, type: 'agent', status: 'running' })),
              { id: 'shell-1', type: 'shell', status: 'running' }] };
          },
          async cancel({ id }) {
            if (id === 'shell-1') throw Error('shell tasks must never be cancelled from the monitor');
            if (!running.delete(id)) return { cancelled: false };
            if (late) {
              // Reversed order: the turn ends before the stop is confirmed.
              emit({ type: 'session.idle', data: {} });
              await new Promise(resolve => setTimeout(resolve, 150));
              return { cancelled: true };
            }
            const queued = id === 'agent-q';
            setTimeout(() => {
              emit({ type: 'session.idle', data: {} });
              emit({ type: 'subagent.completed', agentId: id, data: { toolCallId: queued ? 'task-q' : 'task-1',
                agentName: queued ? 'general-purpose' : 'explore', agentDisplayName: queued ? 'notif-prompts' : 'Find tests',
                cancelled: true, totalTokens: queued ? 0 : 9000, durationMs: 1500 } });
            }, 20);
            return { cancelled: true };
          }
        };
        return {
          rpc: { tasks },
          async abort() {},
          async send(options) {
            if (!options.prompt.includes('spawn')) { emit({ type: 'session.idle', data: {} }); return 'm'; }
            late = options.prompt.includes('late');
            if (options.prompt.includes('queue')) {
              // Copilot CLI 1.0.88 queues a background agent until the root waits for it.
              running.add('agent-q');
              setTimeout(() => {
                emit({ type: 'tool.execution_start', data: { toolCallId: 'task-q', toolName: 'task',
                  arguments: { description: 'Build notification prompts', agent_type: 'general-purpose',
                    name: 'notif-prompts', mode: 'background' } } });
                emit({ type: 'tool.execution_complete', data: { toolCallId: 'task-q', success: true,
                  result: { content: "Agent started in background with agent_id: agent-q. You'll be notified when it completes." } } });
                emit({ type: 'assistant.message', data: { messageId: 'root-q', content: 'Launched the prompts agent.' } });
              }, 10);
              return 'm';
            }
            if (late) {
              running.add('agent-2');
              setTimeout(() => {
                emit({ type: 'tool.execution_start', data: { toolCallId: 'task-2', toolName: 'task',
                  arguments: { description: 'Late stop', mode: 'background' } } });
                emit({ type: 'subagent.started', agentId: 'agent-2', data: { toolCallId: 'task-2',
                  agentName: 'task', agentDisplayName: 'Late stop', agentDescription: '', executionMode: 'background' } });
              }, 10);
              return 'm';
            }
            running.add('agent-1');
            setTimeout(() => {
              emit({ type: 'assistant.reasoning_delta', data: { reasoningId: 'r-1', deltaContent: '**Planning**\n\nSpawn an explorer.' } });
              emit({ type: 'tool.execution_start', data: { toolCallId: 'task-1', toolName: 'task',
                arguments: { description: 'Find tests', agent_type: 'explore', mode: 'background' } } });
              emit({ type: 'tool.execution_complete', data: { toolCallId: 'task-1', success: true,
                result: { content: 'Agent started' } } });
              emit({ type: 'subagent.started', agentId: 'agent-1', data: { toolCallId: 'task-1',
                agentName: 'explore', agentDisplayName: 'Find tests', agentDescription: 'Locate the parser tests',
                model: 'gpt-5.4-mini', agentType: 'explore', executionMode: 'background' } });
              emit({ type: 'assistant.usage', agentId: 'agent-1', data: { inputTokens: 4000, outputTokens: 100 } });
              emit({ type: 'assistant.reasoning', agentId: 'agent-1', data: { reasoningId: 'a-1', content: 'I should search Tests/ first. Then report back.' } });
              emit({ type: 'assistant.intent', agentId: 'agent-1', data: { intent: 'Searching Tests/' } });
              emit({ type: 'tool.execution_start', agentId: 'agent-1', data: { toolCallId: 'grep-1', toolName: 'grep',
                parentToolCallId: 'task-1', arguments: { pattern: 'testSubagent' } } });
              emit({ type: 'assistant.reasoning_delta', data: { reasoningId: 'r-2', deltaContent: 'Wait for the explorer to report.' } });
              emit({ type: 'assistant.message', data: { messageId: 'root-1', content: 'Waiting on the explorer.' } });
            }, 10);
            return 'm';
          }
        };
      }
    }
    """#

    @MainActor
    static func testSubagentMonitor() async throws {
        let settings = AppSettings.shared
        settings.backend = .copilot
        settings.memoryEnabled = false
        settings.attachScreen = false
        settings.shareLocation = false
        settings.shareCalendar = false
        settings.fileRAGEnabled = false

        let sdkURL = "data:text/javascript;base64," + Data(subagentFakeSDK.utf8).base64EncodedString()
        let discovery = "function resolveCopilotRuntime() { return {sdk: '\(sdkURL)', runtime: 'fixture', sessionRuntime: 'fixture'}; }"
        let backend = CopilotBackend(bridgeScript: CopilotSessionBridge.script.replacingOccurrences(
            of: CopilotRuntime.discoveryScript, with: discovery))
        let chat = ChatSession(copilotBackend: backend)
        let manager = SessionManager()
        manager.sessions = [chat]
        let server = RemoteControlServer(manager: manager)
        let port = Int.random(in: 49152...65535), token = UUID().uuidString
        server.start(port: port, token: token)
        defer { server.stop(); chat.cancel() }
        try await Task.sleep(for: .milliseconds(300))

        chat.submit("spawn")
        try await waitForJournalTest {
            chat.subagent(agentID: "agent-1")?.intent != nil && chat.messages.last?.text.isEmpty == false
        }
        let live = try require(chat.subagent(agentID: "agent-1"))
        precondition(live.status == .running && live.background && live.canCancel && live.tokens == 4100,
                     "a live background agent should be tracked with its usage: \(live)")
        let reply = try require(chat.messages.last)
        precondition(reply.text == "Waiting on the explorer.", "subagent progress must stay out of the reply text")

        // Only agent tasks can be stopped; a shell task with a known ID is refused before cancel.
        let shell: Result<Bool, Error> = await withCheckedContinuation { continuation in
            backend.cancelSubagent(agentID: "shell-1") { continuation.resume(returning: $0) }
        }
        guard case .success(false) = shell else { preconditionFailure("shell tasks are not subagents: \(shell)") }

        let base = URL(string: "http://127.0.0.1:\(port)/")!
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        func call(_ path: String, method: String = "GET", body: String? = nil) async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: URL(string: path, relativeTo: base)!)
            request.httpMethod = method
            request.httpBody = body.map { Data($0.utf8) }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await client.data(for: request)
            return ((response as! HTTPURLResponse).statusCode,
                    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
        }
        let snapshot = try await call("api/v1/sessions/\(chat.id)")
        let messages = (snapshot.1["session"] as? [String: Any])?["messages"] as? [[String: Any]] ?? []
        let summary = try require(messages.compactMap { $0["subagents"] as? [[String: Any]] }.first?.first)
        precondition(summary["id"] as? String == "task-1" && summary["agentID"] as? String == "agent-1"
                     && summary["name"] as? String == "Find tests" && summary["agentType"] as? String == "explore"
                     && summary["summary"] as? String == "Locate the parser tests"
                     && summary["status"] as? String == "running" && summary["background"] as? Bool == true
                     && summary["canCancel"] as? Bool == true && summary["tokens"] as? Int == 4100
                     && summary["steps"] as? Int == 1 && summary["intent"] as? String == "Searching Tests/"
                     && summary["model"] as? String == "gpt-5.4-mini" && summary["startedAt"] is Double
                     && summary["finishedAt"] == nil
                     && (summary["recentSteps"] as? [[String: Any]])?.first?["state"] as? String == "running",
                     "snapshots should carry the monitor summary: \(summary)")
        // Cantrip Agent lists reasoning as titled steps, one per block, for the reply and each subagent.
        let reasoning = messages.compactMap { $0["reasoning"] as? [[String: Any]] }.first ?? []
        precondition(reasoning.map { $0["title"] as? String } == ["Planning", "Wait for the explorer to report"]
                     && reasoning.map { $0["number"] as? Int } == [1, 2]
                     && reasoning.first?["text"] as? String == "Spawn an explorer."
                     && reply.thinking == "**Planning**\n\nSpawn an explorer.\n\nWait for the explorer to report.",
                     "reply reasoning should split into steps: \(reasoning) \(reply.thinking.debugDescription)")
        let agentReasoning = summary["reasoning"] as? [[String: Any]] ?? []
        precondition(agentReasoning.map { $0["title"] as? String } == ["I should search Tests/ first"]
                     && agentReasoning.first?["text"] as? String == "Then report back.",
                     "subagent reasoning should reach its card: \(agentReasoning)")
        let unknown = try await call("api/v1/sessions/\(chat.id)/subagents/nope/cancel", method: "POST")
        let wrongMethod = try await call("api/v1/sessions/\(chat.id)/subagents/agent-1/cancel")
        precondition(unknown.0 == 404 && wrongMethod.0 == 405, "\(unknown) \(wrongMethod)")

        // The browser Remote renders a live card and stops the agent from it.
        let (page, _) = try await client.data(from: base)
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let delegate = SubagentPageDelegate()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 420, height: 640), configuration: configuration)
        webView.navigationDelegate = delegate
        let window = NSWindow(contentRect: webView.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        defer { webView.stopLoading(); window.close() }
        webView.loadHTMLString(String(decoding: page, as: UTF8.self), baseURL: base)
        for _ in 0..<200 where !delegate.finished && delegate.error == nil { try await Task.sleep(for: .milliseconds(50)) }
        precondition(delegate.finished, "Remote page should load: \(String(describing: delegate.error))")
        let card = try await webView.callAsyncJavaScript("""
        localStorage.cantripToken=pairing;token=pairing;pair(false);selected=sessionID;
        const data=await api(`/api/v1/sessions/${sessionID}`);render(data.session);
        const cards=[...document.querySelectorAll('#liveSubagents .subagent')];
        const steps=[...document.querySelectorAll('#messages .steps .step')].map(step=>step.textContent);
        const bar=document.getElementById('liveSubagents'),box=document.getElementById('messages');
        return {count:cards.length,text:cards[0]?.textContent||"",stop:Boolean(cards[0]?.querySelector('.subagent-stop')),
          live:Boolean(cards[0]?.querySelector('.subagent-meta[data-live]')),label:cards[0]?.getAttribute('aria-label')||"",steps,
          inline:box.querySelectorAll('.subagent').length,pinnedAfter:box.compareDocumentPosition(bar)===Node.DOCUMENT_POSITION_FOLLOWING,
          sticky:getComputedStyle(bar).position,visible:!bar.classList.contains('hidden')};
        """, arguments: ["pairing": token, "sessionID": chat.id.uuidString], contentWorld: .page) as? [String: Any]
        let cardText = card?["text"] as? String ?? ""
        precondition(card?["count"] as? Int == 1 && card?["stop"] as? Bool == true && card?["live"] as? Bool == true
                     && cardText.contains("Find tests") && cardText.contains("Now: Searching Tests/")
                     && cardText.contains("4.1k tokens") && cardText.contains("Background")
                     && (card?["label"] as? String ?? "").hasPrefix("Find tests subagent, Running"),
                     "the browser should show a live, stoppable card: \(String(describing: card))")
        precondition(card?["inline"] as? Int == 0 && card?["pinnedAfter"] as? Bool == true
                     && card?["sticky"] as? String == "sticky" && card?["visible"] as? Bool == true,
                     "a running subagent should be pinned below the chat, not inline: \(String(describing: card))")
        precondition((card?["steps"] as? [String])?.isEmpty == true,
                     "a subagent's task call should not repeat in the step list: \(String(describing: card))")
        try await snapshotSubagentPage(webView, name: "remote-running")

        let clicked = try await webView.callAsyncJavaScript("""
        window.confirm=()=>true;document.querySelector('#liveSubagents .subagent-stop').click();return true;
        """, contentWorld: .page) as? Bool
        precondition(clicked == true)
        try await waitForJournalTest { chat.subagent(agentID: "agent-1")?.status == .cancelled && !chat.isStreaming }
        let stopped = try require(chat.subagent(agentID: "agent-1"))
        precondition(stopped.finishedAt != nil && !stopped.canCancel, "a stopped agent should be final: \(stopped)")
        let task = try require(chat.messages.last?.activities.first { $0.id == "task-1" })
        precondition(task.children.map(\.state) == [.cancelled], "the stopped agent's running step should stop")

        var rendered = ""
        var pinnedLeft = false
        var afterText = false
        for _ in 0..<60 {
            rendered = try await webView.evaluateJavaScript(
                "document.querySelector('#messages .subagent')?.textContent || ''") as? String ?? ""
            pinnedLeft = try await webView.evaluateJavaScript(
                "document.getElementById('liveSubagents').classList.contains('hidden') && !document.querySelector('#liveSubagents .subagent')") as? Bool ?? false
            afterText = try await webView.evaluateJavaScript("""
                (()=>{const card=document.querySelector('#messages .subagent'),prose=card?.closest('.message')?.querySelector(':scope>.prose');
                return Boolean(card&&prose&&prose.textContent.includes('Waiting on the explorer.')&&(prose.compareDocumentPosition(card)&Node.DOCUMENT_POSITION_FOLLOWING))})()
                """) as? Bool ?? false
            if rendered.contains("Stopped") && pinnedLeft && afterText { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        precondition(rendered.contains("Stopped") && !rendered.contains("Now:") && pinnedLeft,
                     "the stopped card should move back into its reply: \(rendered) pinnedLeft=\(pinnedLeft)")
        precondition(afterText, "the stopped card should follow the text written before it ended")
        let settled = try await call("api/v1/sessions/\(chat.id)")
        let settledAgent = ((settled.1["session"] as? [String: Any])?["messages"] as? [[String: Any]])?
            .compactMap { $0["subagents"] as? [[String: Any]] }.first?.first
        precondition(settledAgent?["textBlock"] as? Int == 1, "\(String(describing: settledAgent))")
        let again = try await call("api/v1/sessions/\(chat.id)/subagents/agent-1/cancel", method: "POST", body: "{}")
        precondition(again.0 == 409 && (again.1["error"] as? String)?.contains("already finished") == true, "\(again)")
        try await snapshotSubagentPage(webView, name: "remote-stopped")

        // A stop confirmed after the turn already finished still reads as stopped.
        chat.submit("spawn late")
        try await waitForJournalTest { chat.subagent(agentID: "agent-2")?.status == .running }
        var lateResult: Result<Bool, Error>?
        chat.cancelSubagent(agentID: "agent-2") { lateResult = $0 }
        try await waitForJournalTest { lateResult != nil && !chat.isStreaming }
        guard case .success(true) = lateResult else { preconditionFailure("\(String(describing: lateResult))") }
        precondition(chat.subagent(agentID: "agent-2")?.status == .cancelled,
                     "a late-confirmed stop must not read as done: \(String(describing: chat.subagent(agentID: "agent-2")))")

        // A queued background agent shows from its launch, pinned, and can be stopped before it starts.
        chat.submit("spawn queue")
        try await waitForJournalTest {
            chat.subagent(agentID: "agent-q")?.status == .queued && chat.messages.last?.text.isEmpty == false
        }
        let queued = try require(chat.subagent(agentID: "agent-q"))
        precondition(queued.name == "notif-prompts" && queued.background && queued.canCancel,
                     "a queued agent should be identified and stoppable: \(queued)")
        let queuedSnapshot = try await call("api/v1/sessions/\(chat.id)")
        let queuedSummary = ((queuedSnapshot.1["session"] as? [String: Any])?["messages"] as? [[String: Any]])?
            .last?["subagents"] as? [[String: Any]]
        precondition(queuedSummary?.first?["status"] as? String == "queued"
                     && queuedSummary?.first?["canCancel"] as? Bool == true
                     && queuedSummary?.first?["textBlock"] == nil,
                     "remote clients should see the queued agent: \(String(describing: queuedSummary))")
        let queuedCard = try await webView.callAsyncJavaScript("""
        const data=await api(`/api/v1/sessions/${sessionID}`);render(data.session);
        const card=document.querySelector('#liveSubagents .subagent');
        return {text:card?.textContent||"",stop:Boolean(card?.querySelector('.subagent-stop')),
          inline:[...document.querySelectorAll('#messages .subagent')].filter(inline=>inline.textContent.includes('notif-prompts')).length,label:card?.getAttribute('aria-label')||""};
        """, arguments: ["sessionID": chat.id.uuidString], contentWorld: .page) as? [String: Any]
        let queuedText = queuedCard?["text"] as? String ?? ""
        precondition(queuedText.contains("notif-prompts") && queuedText.contains("Queued")
                     && queuedText.contains("Starts when the main agent waits for it")
                     && queuedCard?["stop"] as? Bool == true && queuedCard?["inline"] as? Int == 0
                     && (queuedCard?["label"] as? String ?? "").contains("Queued"),
                     "the browser should pin the queued agent's card: \(String(describing: queuedCard))")
        try await snapshotSubagentPage(webView, name: "remote-queued")
        var queuedStop: Result<Bool, Error>?
        chat.cancelSubagent(agentID: "agent-q") { queuedStop = $0 }
        try await waitForJournalTest { queuedStop != nil && !chat.isStreaming }
        guard case .success(true) = queuedStop else { preconditionFailure("\(String(describing: queuedStop))") }
        let queuedEnd = try require(chat.messages.last)
        let queuedTask = try require(queuedEnd.activities.first { $0.id == "task-q" })
        precondition(queuedTask.subagent?.status == .cancelled && queuedEnd.subagentTextBlock("task-q") == 1,
                     "a queued agent stopped after the reply's text should sit after it: \(String(describing: queuedTask.subagent))")

        // Non-SDK backends can show subagents but not stop them.
        let fixture = MCPAppLikeFixture()
        let other = ChatSession(copilotBackend: fixture)
        defer { other.cancel() }
        other.submit("Delegate")
        try await waitForJournalTest { fixture.sink != nil }
        var claudeTask = ToolActivityFactory.start(id: "tool-9", toolName: "Task", arguments: ["description": "Review"])
        claudeTask.subagent = SubagentInfo(agentID: "tool-9", name: "Review", agentType: "code-reviewer", summary: "")
        fixture.sink?(.activity(claudeTask))
        try await waitForJournalTest { other.subagent(agentID: "tool-9") != nil }
        var refused: Error?
        other.cancelSubagent(agentID: "tool-9") { if case .failure(let error) = $0 { refused = error } }
        precondition(refused as? SubagentCancelError == .unsupported, "\(String(describing: refused))")
        fixture.sink?(.done)
        try await waitForJournalTest { !other.isStreaming }
        precondition(other.subagent(agentID: "tool-9")?.status == .completed,
                     "a finished turn should end its subagents")

        try snapshotSubagentViews()
        print("Subagent monitor: live tracking, remote summaries, browser cards, per-agent stop, and finalization passed")
    }

    /// A finished subagent's card sits where the reply had got to when it ended.
    static func testSubagentPlacement() throws {
        let fenced = "A\n\nB\nC\n\n```\nx\n\ny\n```\n\nD"
        precondition(ReplyBlocks.starts(in: fenced).count == 4, "blank lines inside a code fence don't split blocks")
        precondition(ReplyBlocks.split(fenced, before: [3]) == ["A\n\nB\nC\n\n```\nx\n\ny\n```", "D"],
                     "\(ReplyBlocks.split(fenced, before: [3]))")
        precondition(ReplyBlocks.split("é👍\n\nNext", before: [1]) == ["é👍", "Next"], "splits on UTF-8 boundaries")
        precondition(ReplyBlocks.split("A\r\n\r\nB", before: [1]) == ["A", "B"], "CRLF blank lines split like the browser")
        precondition(ReplyBlocks.split("Only", before: [0, 5]) == ["", "Only", ""], "0 = before the text, past the end = after")
        precondition(ReplyBlocks.block(atOffset: 8, in: "Para one is long\n\nPara two") == 1,
                     "ending mid-paragraph places the card after that paragraph")

        var message = ChatMessage(role: .assistant, text: "Starting an explorer.")
        var task = ToolActivityFactory.start(id: "task-a", toolName: "task", arguments: [:])
        task.subagent = SubagentInfo(agentID: "a", name: "Explore", agentType: "explore", summary: "")
        message.activities = [task]
        message.text += "\n\nStill waiting."
        precondition(message.subagentEnds.isEmpty, "a running agent has no place in the text yet")
        task.subagent?.status = .completed
        message.activities[0] = task
        message.text += "\n\nIt found three tests."
        precondition(message.subagentTextBlock("task-a") == 2, "\(message.subagentEnds)")
        precondition(ReplyBlocks.split(message.text, before: [2])
                     == ["Starting an explorer.\n\nStill waiting.", "It found three tests."])
        let remote = RemoteHistory.message(message)["subagents"] as? [[String: Any]]
        precondition(remote?.first?["textBlock"] as? Int == 2, "\(String(describing: remote))")

        // A revived agent (e.g. a background agent given more work) is placed where it ends next.
        task.subagent?.status = .running
        message.activities[0] = task
        precondition(message.subagentEnds.isEmpty
                     && (RemoteHistory.message(message)["subagents"] as? [[String: Any]])?.first?["textBlock"] == nil)
        message.text += "\n\nMore."
        task.subagent?.status = .failed
        message.activities[0] = task
        precondition(message.subagentTextBlock("task-a") == 4, "\(message.subagentEnds)")
        print("Subagent placement: cards follow the reply block that was streaming when each agent ended")
    }

    private static func require<T>(_ value: T?, line: UInt = #line) throws -> T {
        guard let value else { preconditionFailure("missing value at line \(line)") }
        return value
    }

    /// Writes PNGs for review when CANTRIP_SNAPSHOT_DIR is set.
    @MainActor
    private static func snapshotSubagentPage(_ webView: WKWebView, name: String) async throws {
        guard let directory = ProcessInfo.processInfo.environment["CANTRIP_SNAPSHOT_DIR"] else { return }
        for dark in [false, true] {
            webView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            try await Task.sleep(for: .milliseconds(300))
            let image = try await webView.takeSnapshot(configuration: nil)
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { continue }
            try png.write(to: URL(fileURLWithPath: directory)
                .appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        }
    }

    @MainActor
    private static func snapshotSubagentViews() throws {
        guard let directory = ProcessInfo.processInfo.environment["CANTRIP_SNAPSHOT_DIR"] else { return }
        let start = Date().addingTimeInterval(-83)
        func agent(_ id: String, _ name: String, _ type: String, _ status: SubagentInfo.Status,
                   background: Bool = false, intent: String? = nil, tokens: Int, error: String? = nil,
                   steps: [ToolActivityState]) -> ToolActivity {
            var activity = ToolActivityFactory.start(id: id, toolName: "task", arguments: ["description": name])
            activity.state = status == .running ? .running : .succeeded
            activity.subagent = SubagentInfo(
                agentID: id, name: name, agentType: type, summary: "Find every caller of the parser and report file:line",
                model: "gpt-5.4-mini", background: background, status: status, startedAt: start,
                finishedAt: status.isFinal ? start.addingTimeInterval(47) : nil, intent: intent,
                latestMessage: "Found 3 callers in Sources/Cantrip.", tokens: tokens, error: error, canCancel: !status.isFinal)
            activity.children = steps.enumerated().map { index, state in
                var step = ToolActivityFactory.start(id: "\(id)-\(index)", toolName: index % 2 == 0 ? "grep" : "view",
                                                     arguments: ["pattern": "CopilotJSONStreamParser"])
                step.state = state
                return step
            }
            return activity
        }
        let agents = [
            agent("a", "Map parser callers", "explore", .running, intent: "Reading MessageRouter.swift",
                  tokens: 8_412, steps: [.succeeded, .succeeded, .running]),
            agent("b", "Run session-tab tests", "task", .idle, background: true, tokens: 21_870, steps: [.succeeded]),
            agent("q", "Build notification prompts", "general-purpose", .queued, background: true, tokens: 0, steps: []),
            agent("c", "Review the diff", "code-review", .completed, tokens: 120_400, steps: [.succeeded, .succeeded]),
            agent("d", "Check iOS build", "task", .failed, tokens: 950, error: "xcodebuild exited with 65",
                  steps: [.failed]),
        ]
        for dark in [false, true] {
            let content = VStack(alignment: .leading, spacing: 10) {
                SubagentStrip(activities: agents, open: {})
                SubagentMonitorView(activities: agents, stop: { _, done in done(nil) })
            }
            .padding(12)
            .frame(width: 300)
            .background(dark ? Color.black : Color.white)
            .environment(\.colorScheme, dark ? .dark : .light)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { continue }
            try png.write(to: URL(fileURLWithPath: directory)
                .appendingPathComponent("mac-monitor-\(dark ? "dark" : "light").png"))
        }
    }
}

private final class MCPAppLikeFixture: Backend {
    var sink: ((BackendEvent) -> Void)?
    func send(_ request: BackendRequest, workdir: String, onEvent: @escaping (BackendEvent) -> Void) { sink = onEvent }
    func cancel() {}
    func reset() {}
}

private extension SubagentInfo.Status {
    var isFinal: Bool { self == .completed || self == .failed || self == .cancelled }
}
