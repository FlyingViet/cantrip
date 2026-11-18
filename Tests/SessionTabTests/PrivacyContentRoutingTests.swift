import Foundation

extension SessionTabTests {
    /// Content-aware routing for scheduled tasks (observe only), with synthetic tools and results.
    static func testPrivacyContentRouting() async throws {
        typealias S = PrivacyContentSources
        let settings = PrivacyContentRoutingSettings()

        // Layer 1: sources by tool name, command and path; status checks read nothing private.
        precondition(S.sources(tool: "personal-mail_search", input: nil, settings: settings) == [.mail])
        precondition(S.sources(tool: "mcp__personal__messages_read", input: nil, settings: settings) == [.messages])
        precondition(S.sources(tool: "homelab-firefly_transactions", input: nil, settings: settings) == [.finance])
        precondition(S.sources(tool: "homelab-paperless_search", input: nil, settings: settings) == [.documents])
        precondition(S.sources(tool: "bitwarden-get", input: nil, settings: settings) == [.passwords])
        precondition(S.sources(tool: "bitwarden-status", input: nil, settings: settings).isEmpty
                     && S.sources(tool: "personal-personal_status", input: nil, settings: settings).isEmpty)
        precondition(S.sources(tool: "bash", input: "sqlite3 ~/Library/Messages/chat.db 'select 1'", settings: settings) == [.messages])
        precondition(S.sources(tool: "bash", input: "git status && df -h", settings: settings).isEmpty)
        var custom = settings
        custom.privatePaths = ["inbox-export.py": .mail]
        precondition(S.sources(tool: "bash", input: "python3 inbox-export.py --since 1d", settings: custom) == [.mail])

        // What a task needs comes from its prompt and its recent runs' tools, not the tools it can use.
        let fromPrompt = S.needed(prompt: "Check my inbox and bank transactions every morning", history: [:], settings: settings)
        precondition(fromPrompt == .init(sources: [.mail, .finance], basis: ["prompt"]), "\(fromPrompt)")
        let fromHistory = S.needed(prompt: "Summarize what changed overnight", history: ["personal-mail_search": 3], settings: settings)
        precondition(fromHistory == .init(sources: [.mail], basis: ["history"]), "\(fromHistory)")
        precondition(S.needed(prompt: "Delete build folders older than 14 days", history: ["bash": 9], settings: settings).sources.isEmpty)
        precondition(S.preRoute([]) == .cloud && S.preRoute([.finance]) == .cloudRedacted
                     && S.preRoute([.mail, .finance]) == .hybrid && S.preRoute([.mail, .passwords]) == .local)
        precondition(S.route([.pass: 4]) == .cloud && S.route([.pass: 4, .redact: 1]) == .cloudRedacted
                     && S.route([.redact: 1, .extract: 2]) == .hybrid && S.route([.extract: 2, .local: 1]) == .local)

        // Layer 2: the judge asks /judgments twice (options forward and reversed) and takes the
        // highest averaged label; passwords are never sent to it.
        let endpoint = PrivacyClassifierEndpoint(baseURL: URL(string: "https://model-server.local/v1")!, model: "m")
        final class Calls: @unchecked Sendable { var count = 0; let lock = NSLock()
            func add() { lock.lock(); count += 1; lock.unlock() } }
        let calls = Calls()
        let byMarker: [String: PrivacyResultLabel] = ["NEWSLETTER": .pass, "INVOICE": .redact, "THREAD": .extract, "LAB": .local]
        let transport: PrivacyClassifier.Transport = { request in
            calls.add()
            guard request.url?.lastPathComponent == "judgments" else { return (Data(), notFound(request)) }
            let row = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let state = row["state"] as! String
            let want = byMarker.first { state.contains($0.key) }?.value ?? .pass
            let ids = (row["options"] as! [[String: Any]]).map { $0["id"] as! String }
            let data = try JSONSerialization.data(withJSONObject: [
                "option_ids": ids, "probabilities": ids.map { $0 == want.rawValue ? 0.85 : 0.05 }])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let judge = PrivacyResultJudge(transport: transport)
        let bodies = try PrivacyResultJudge.bodies(tool: "personal-mail_read", result: "THREAD body", model: "m", characters: 3000)
            .map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] }
        let firsts = bodies.map { (($0["options"] as! [[String: Any]]).first!["id"] as! String) }
        precondition(firsts == ["pass", "local"] && bodies.allSatisfy { $0["priority"] as? String == "background" }, "\(firsts)")
        for (marker, label) in byMarker {
            let got = await judge.judge(tool: "personal-mail_read", result: "\(marker) text", endpoint: endpoint, settings: settings)
            precondition(got == label, "\(marker): \(String(describing: got))")
        }
        let before = calls.count
        let password = await judge.judge(tool: "bitwarden-get", result: "secret", endpoint: endpoint, settings: settings)
        precondition(password == .local && calls.count == before, "passwords stay local without asking")

        // A whole run: judged results become one log line with labels and counts, no content.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("content-routing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        final class Box: @unchecked Sendable { var records: [PrivacyContentRecord] = [] }
        let box = Box()
        let routing = PrivacyContentRouting(directory: directory, append: { box.records.append($0) })
        routing.judge = judge
        var gate = PrivacyGateSettings()
        gate.contentRouting.factRatio = 0.1
        let taskID = UUID(), run = UUID()
        let plan = routing.begin(run: run, taskID: taskID, taskTitle: "Synthetic tracker",
                                 prompt: "Scheduled task · Synthetic tracker\n\nRead new mail and update the records.",
                                 gateRoute: nil, gate: gate, endpoint: endpoint)
        precondition(plan.preRoute == .hybrid && plan.need.sources == [.mail], "\(plan)")
        routing.noteGateRoute(run: run, route: "local")
        let thread = String(repeating: "THREAD ", count: 100)
        routing.observe(run: run, activityID: "a1", tool: "personal-mail_read", input: "{}", output: thread)
        routing.observe(run: run, activityID: "a1", tool: "personal-mail_read", input: "{}", output: thread)
        routing.observe(run: run, activityID: "a2", tool: "bash", input: "git log -1", output: "NEWSLETTER-free commit line")
        routing.observe(run: run, activityID: "a3", tool: "bitwarden-get", input: "{}", output: "secret")
        routing.observe(run: run, activityID: "a4", tool: "edit", input: "notes.md", output: "File updated")
        routing.observe(run: run, activityID: "a5", tool: "web_fetch", input: "https://example.com", output: "public page")
        guard let record = await routing.finish(run: run) else { preconditionFailure("a record") }
        precondition(record.gateRoute == "local" && record.preRoute == "hybrid" && record.route == "local"
                     && record.labels == ["extract": 1, "pass": 1, "local": 1] && record.unchecked == 0
                     && record.publicResults == 1 && record.publicChars == 11
                     && record.cloudChars == 11 + 27 + Int((Double(thread.count) * 0.1).rounded())
                     && record.rawChars == 11 + 27 + thread.count + 6 && box.records == [record], "\(record)")
        let line = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        precondition(!line.contains("THREAD") && !line.contains("secret") && !line.contains("example.com"), "no content in the log")
        // The run's tools feed the next run's plan, even when its prompt names no source.
        precondition(routing.history(taskID)["personal-mail_read\u{1F}mail"] == 1)
        let next = routing.begin(run: UUID(), taskID: taskID, taskTitle: nil, prompt: "Update the records.",
                                 gateRoute: nil, gate: gate, endpoint: endpoint)
        precondition(next.need == .init(sources: [.mail, .passwords], basis: ["history"]) && next.preRoute == .local, "\(next)")

        // Live runs name shell and file tools for display ("Shell", "Read"); in a run that needs a
        // private source their output is judged, like bash and view.
        let shown = UUID()
        _ = routing.begin(run: shown, taskID: UUID(), taskTitle: nil, prompt: "Read my email", gateRoute: nil, gate: gate, endpoint: endpoint)
        routing.observe(run: shown, activityID: "d1", tool: "Shell", input: "python3 digest.py", output: "INVOICE 0042 due")
        routing.observe(run: shown, activityID: "d2", tool: "Read", input: "/tmp/notes.md", output: "THREAD notes")
        let shownRecord = await routing.finish(run: shown)
        precondition(shownRecord?.labels == ["redact": 1, "extract": 1] && shownRecord?.publicResults == 0,
                     "\(String(describing: shownRecord))")

        // Past the per-run cap, results are counted as unchecked; a run that needs nothing private
        // sends shell output as is, unjudged.
        gate.contentRouting.maxResultsPerRun = 1
        let capped = UUID()
        _ = routing.begin(run: capped, taskID: UUID(), taskTitle: nil, prompt: "Read my email", gateRoute: nil, gate: gate, endpoint: endpoint)
        routing.observe(run: capped, activityID: "b1", tool: "personal-mail_search", input: nil, output: "THREAD")
        routing.observe(run: capped, activityID: "b2", tool: "personal-mail_search", input: nil, output: "THREAD")
        let cappedRecord = await routing.finish(run: capped)
        precondition(cappedRecord?.labels == ["extract": 1] && cappedRecord?.unchecked == 1, "\(String(describing: cappedRecord))")
        let plain = UUID()
        let callsBefore = calls.count
        _ = routing.begin(run: plain, taskID: UUID(), taskTitle: nil, prompt: "Delete old build folders",
                          gateRoute: "cloud", gate: gate, endpoint: endpoint)
        routing.observe(run: plain, activityID: "c1", tool: "bash", input: "du -sh builds", output: "12G builds")
        let plainRecord = await routing.finish(run: plain)
        precondition(plainRecord?.route == "cloud" && plainRecord?.publicResults == 1 && calls.count == callsBefore)
        // Observing off: no run is tracked.
        gate.contentRouting.observe = false
        let off = UUID()
        _ = routing.begin(run: off, taskID: UUID(), taskTitle: nil, prompt: "Read my email", gateRoute: nil, gate: gate, endpoint: endpoint)
        precondition(!routing.isObserving(off))

        // The gate's own decision line carries the pre-run route; the report shows both routes.
        let gateDir = directory.appendingPathComponent("gate")
        let privacyGate = PrivacyGate(directory: gateDir)
        let request = PrivacyGateRequest(kind: .homeTask, taskID: taskID, taskTitle: "Synthetic tracker", conversationKey: "task",
                                         request: "Read new mail", earlier: "", message: "Read new mail", workdir: "/tmp",
                                         backend: "copilot")
        let decision = PrivacyDecision(route: .local, source: .rule, rule: "private-sources", reason: "synthetic", hits: [:],
                                       rulesMs: 1)
        privacyGate.record(decision, request: request, settings: PrivacyGateSettings(), applied: false, totalMs: 1, content: plan)
        privacyGate.appendContent(record)
        let logged = privacyGate.records(since: .distantPast)
        precondition(logged.count == 1 && logged[0].contentRoute == "hybrid" && logged[0].contentSources == ["mail"]
                     && logged[0].contentBasis == ["prompt"], "\(logged.map { ($0.contentRoute, $0.contentSources, $0.contentBasis) }) \(logged.count)")
        let reread = privacyGate.contentRecords(since: .distantPast)
        precondition(reread.count == 1 && reread[0].labels == record.labels && reread[0].cloudChars == record.cloudChars
                     && abs(reread[0].at.timeIntervalSince(record.at)) < 1, "\(reread)")
        let report = privacyGate.report(days: 1)
        precondition(report.contains("Content-aware routing") && report.contains("gate local 1 -> content local 1")
                     && report.contains("extract 33%"), report)
        print("Privacy content routing: sources, plans, judged results, run records, history and report passed")
    }
}
