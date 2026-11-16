import Foundation
import JavaScriptCore

extension SessionTabTests {
    /// Text written before a reply's last tool call is progress notes; clients fold it above the answer.
    @MainActor
    static func testReplyWorkSplit() async throws {
        let settings = AppSettings.shared
        let saved = (settings.backend, settings.memoryEnabled, settings.attachScreen, settings.shareLocation,
                     settings.shareCalendar, settings.fileRAGEnabled)
        defer {
            (settings.backend, settings.memoryEnabled, settings.attachScreen, settings.shareLocation,
             settings.shareCalendar, settings.fileRAGEnabled) = saved
        }
        settings.backend = .copilot
        settings.memoryEnabled = false; settings.attachScreen = false
        settings.shareLocation = false; settings.shareCalendar = false; settings.fileRAGEnabled = false
        let backend = WorkSplitFixture()
        let chat = ChatSession(copilotBackend: backend)
        defer { chat.cancel() }
        chat.submit("Check the build")
        try await waitForJournalTest { backend.sink != nil }
        func reply() throws -> ChatMessage { try requireHome(chat.messages.last { $0.role == .assistant }) }

        backend.sink?(.textDelta("Checking the build."))
        try await waitForJournalTest { (try? reply().text) == "Checking the build." }
        let first = try reply()
        precondition(first.workSplit == nil, "text with no tool call after it is the answer")
        backend.sink?(.activity(ToolActivityFactory.start(id: "t1", toolName: "bash", arguments: [:])))
        try await waitForJournalTest { (try? reply().activities.count) == 1 }
        var running = try reply()
        precondition(running.workSplit == WorkSplit(noteBlocks: 1, notes: 1, steps: 1, hasAnswer: false),
                     "\(String(describing: running.workSplit))")
        var finished = ToolActivityFactory.start(id: "t1", toolName: "bash", arguments: [:])
        finished.state = .succeeded
        backend.sink?(.activity(finished))
        try await waitForJournalTest { (try? reply().activities.first?.state) == .succeeded }
        running = try reply()
        precondition(running.toolMarks.count == 1, "an update to the same tool call isn't a new step")

        // Text glued straight after a tool call still starts its own paragraph.
        backend.sink?(.textDelta("Found the log."))
        backend.sink?(.activity(ToolActivityFactory.start(id: "t2", toolName: "view", arguments: [:])))
        backend.sink?(.activity(ToolActivityFactory.start(id: "t3", toolName: "grep", arguments: [:])))
        backend.sink?(.textDelta("\nThe build passed.\n\n- 12 tests\n- 0 failures"))
        backend.sink?(.done)
        try await waitForJournalTest { !chat.isStreaming }
        let done = try reply()
        precondition(done.text == "Checking the build.\n\nFound the log.\n\nThe build passed.\n\n- 12 tests\n- 0 failures",
                     "\(done.text.debugDescription)")
        precondition(done.workSplit == WorkSplit(noteBlocks: 2, notes: 2, steps: 3, hasAnswer: true),
                     "\(String(describing: done.workSplit))")
        precondition(ReplyBlocks.split(done.text, before: [2])
                     == ["Checking the build.\n\nFound the log.", "The build passed.\n\n- 12 tests\n- 0 failures"])

        // Saved with the transcript, and sent to clients by block.
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(done))
        precondition(decoded.toolMarks == done.toolMarks && decoded.workSplit == done.workSplit)
        let work = try requireHome(RemoteHistory.message(done)["work"] as? [String: Any])
        precondition(work["noteBlocks"] as? Int == 2 && work["notes"] as? Int == 2
                     && work["steps"] as? Int == 3 && work["hasAnswer"] as? Bool == true, "\(work)")

        // No notes: a tool call before any text, or none at all, or an older saved message.
        var direct = ChatMessage(role: .assistant, text: "")
        direct.toolMarks = [0]
        direct.text = "Here it is."
        precondition(direct.workSplit == nil && RemoteHistory.message(direct)["work"] == nil)
        let legacy = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(
            ChatMessage(role: .assistant, text: "Old reply.\n\nStill old.")))
        precondition(legacy.toolMarks.isEmpty && legacy.workSplit == nil)
        let user = ChatMessage(role: .user, text: "Hi")
        precondition(user.workSplit == nil)
        try testReplyWorkSplitWeb()
        print("Reply work split: notes before the last tool call fold, the answer stays, and marks persist")
    }

    /// The browser folds `work.noteBlocks` blocks above the answer: a count when done, Working and
    /// the latest note while running; subagent cards stay on their side of the cut.
    @MainActor
    private static func testReplyWorkSplitWeb() throws {
        let source = try String(contentsOfFile: "Sources/Cantrip/RemoteControlServer.swift", encoding: .utf8)
        func slice(_ from: String, _ to: String) -> String {
            let start = source.range(of: from)!
            let end = source.range(of: to, range: start.upperBound..<source.endIndex)!
            return String(source[start.lowerBound..<end.lowerBound]).replacingOccurrences(of: "\\\\", with: "\\")
        }
        let script = slice("    function replyBlockStarts(", "\n") + "\n"
            + slice("    // Notes a reply wrote between tool calls", "    // Running subagents stay pinned")
        let context = JSContext()!
        context.exceptionHandler = { _, error in fatalError(error!.toString()) }
        context.evaluateScript("""
        function node(tag){return {tag,children:[],dataset:{},className:"",textContent:"",append(...items){this.children.push(...items)}}}
        const document={createElement:node};let placed=[];
        function remember(details){return details}
        function statusIcon(state){const icon=node("span");icon.textContent=state;return icon}
        function appendProse(parent,text){const prose=node("div");prose.className="prose";prose.textContent=text;parent.append(prose)}
        function appendSubagents(parent,agents,sessionID,messageID,block){placed.push({parent:parent.className,block,ids:agents.map(a=>a.id).join()})}
        """)
        context.evaluateScript(script)
        context.evaluateScript("""
        const notes="Checking the log.\\n\\nFound the **failing** step.",answer="It passed.\\n\\n- one fix";
        const done={id:"r1",role:"assistant",text:notes+"\\n\\n"+answer,work:{noteBlocks:2,notes:2,steps:5,hasAnswer:true}};
        globalThis.row=node("article");appendReplyText(row,done,done.text,[{id:"a",textBlock:1},{id:"b",textBlock:4}],{id:"s",messages:[done]});
        globalThis.fold=row.children[0];globalThis.body=fold.children[1];
        """)
        precondition(context.evaluateScript("""
        fold.className==="disclosure work-notes" && fold.children[0].children[1].textContent==="2 notes · 5 steps"
          && body.children.map(c=>c.textContent).join("|")==="Checking the log.|Found the **failing** step."
          && row.children[1].textContent===answer && row.children.length===2
        """)!.toBool(), "\(context.evaluateScript("JSON.stringify(row)")!)")
        precondition(context.evaluateScript("""
        JSON.stringify(placed)===JSON.stringify([{parent:"disclosure-body work-notes-body",block:1,ids:"a"},{parent:"",block:4,ids:"b"}])
        """)!.toBool(), "\(context.evaluateScript("JSON.stringify(placed)")!)")
        context.evaluateScript("""
        const live={id:"r2",role:"assistant",text:notes,work:{noteBlocks:2,notes:2,steps:3,hasAnswer:false}};
        globalThis.liveRow=node("article");appendReplyText(liveRow,live,live.text,[],{id:"s",isStreaming:true,messages:[done,live]});
        globalThis.ended=node("article");appendReplyText(ended,live,live.text,[],{id:"s",isStreaming:false,messages:[live]});
        globalThis.older=node("article");appendReplyText(older,{...done,work:undefined},done.text,[],{id:"s",messages:[]});
        """)
        precondition(context.evaluateScript("""
        liveRow.children[0].children[0].children[1].textContent==="Working · 3 steps"
          && liveRow.children[0].children[0].children[2].textContent==="Found the failing step."
        """)!.toBool(), "\(context.evaluateScript("JSON.stringify(liveRow)")!)")
        precondition(context.evaluateScript("ended.children.length===1 && ended.children[0].textContent===notes")!.toBool(),
                     "a finished run with no answer after its notes shows them in full")
        precondition(context.evaluateScript("older.children.length===1 && older.children[0].textContent===done.text")!.toBool(),
                     "replies from before the split show as before")
    }

    private typealias WorkSplit = ChatMessage.WorkSplit
}

private final class WorkSplitFixture: Backend {
    var sink: ((BackendEvent) -> Void)?
    func send(_ request: BackendRequest, workdir: String, onEvent: @escaping (BackendEvent) -> Void) { sink = onEvent }
    func cancel() {}
    func reset() {}
}
