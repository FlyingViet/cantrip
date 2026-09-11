import Foundation

extension SessionTabTests {
    @MainActor
    static func waitForJournalTest(line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(condition(), "Timed out waiting for journal lifecycle at line \(line)")
    }

    @MainActor
    static func testJournalDelivery() async throws {
        AppSettings.shared.memoryEnabled = false
        AppSettings.shared.voiceMode = false
        for action in ["finish", "cancel", "redirect"] {
            let supersede = action != "finish"
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            var heldTerminal = false
            let chat = ChatSession(makeJournal: { id in
                let url = RunJournal.defaultDirectory.appendingPathComponent("\(id.uuidString).jsonl")
                return try RunJournal(sessionID: id) { handle in
                    if !heldTerminal, RunJournal.loadEvents(from: url).last?.kind == .result {
                        heldTerminal = true
                        entered.signal()
                        guard release.wait(timeout: .now() + 6) == .success else {
                            throw CocoaError(.fileWriteUnknown)
                        }
                    }
                    try handle.synchronize()
                }
            })
            var completions = 0
            chat.onRunFinished = { completions += 1 }
            chat.submitRemote("! /usr/bin/printf journal-fixture")
            var reached = false
            try await waitForJournalTest {
                if !reached { reached = entered.wait(timeout: .now()) == .success }
                return reached
            }
            try await Task.sleep(nanoseconds: 30_000_000)
            precondition(chat.isStreaming && chat.statusText == "Saving run..." && completions == 0,
                         "a run cannot appear completed before its terminal fsync")
            if supersede {
                if action == "cancel" {
                    chat.cancel()
                    precondition(!chat.isStreaming, "Stop remains immediate during a pending disk write")
                    chat.submitRemote("! /usr/bin/printf next-fixture")
                } else {
                    chat.submitRemote("! /usr/bin/printf next-fixture", mode: .interrupt)
                }
                precondition(chat.isStreaming)
            }
            release.signal()
            try await waitForJournalTest { !chat.isStreaming }
            precondition(chat.journalError == nil && completions == 1,
                         "a stale disk completion cannot finish or notify a superseding run")
            let events = RunJournal.loadEvents(from: RunJournal.defaultDirectory
                .appendingPathComponent("\(chat.id.uuidString).jsonl"))
            precondition(events.filter { $0.kind == .result }.count == (supersede ? 2 : 1))
        }

        let failed = ChatSession(makeJournal: { id in
            try RunJournal(sessionID: id) { _ in throw CocoaError(.fileWriteOutOfSpace) }
        })
        var notified = false
        failed.onRunFinished = { notified = true }
        failed.submitRemote("! /usr/bin/printf must-not-start")
        try await waitForJournalTest { !failed.isStreaming }
        precondition(failed.journalError != nil && !notified)
        precondition(failed.messages.contains { $0.role == .error && $0.text.contains("could not be saved") })
        precondition(!failed.messages.contains { $0.role == .assistant && $0.text.contains("must-not-start") },
                     "the backend cannot start before the turn's durable boundary")

        try await testMutationJournalBarrier()
        print("Journal background delivery, durable completion, failure and stale-callback tests passed")
    }

    @MainActor
    static func testMutationJournalBarrier() async throws {
        let manager = SessionManager()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var syncCount = 0
        let chat = ChatSession(makeJournal: { id in
            try RunJournal(sessionID: id) { handle in
                syncCount += 1
                if syncCount == 1 {
                    entered.signal()
                    guard release.wait(timeout: .now() + 6) == .success else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
                try handle.synchronize()
            }
        })
        manager.sessions = [chat]
        let port = Int.random(in: 49152...65535)
        let token = UUID().uuidString
        let server = RemoteControlServer(manager: manager)
        server.start(port: port, token: token)
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 300_000_000)
        let base = URL(string: "http://127.0.0.1:\(port)")!
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        chat.submitRemote("! /usr/bin/true")
        var reached = false
        try await waitForJournalTest {
            if !reached { reached = entered.wait(timeout: .now()) == .success }
            return reached
        }
        var mutation = URLRequest(url: base.appendingPathComponent("api/v1/sessions/\(chat.id)/metadata"))
        mutation.httpMethod = "POST"
        mutation.httpBody = Data(#"{"customTitle":"Durable tab"}"#.utf8)
        mutation.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var acknowledged = false
        let pending = Task {
            let result = try await client.data(for: mutation)
            acknowledged = true
            return result
        }
        try await waitForJournalTest { chat.title == "Durable tab" }
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(!acknowledged, "mutation success must wait for pending journal writes")
        let (_, health) = try await client.data(from: base.appendingPathComponent("health"))
        precondition((health as! HTTPURLResponse).statusCode == 200,
                     "blocked journal I/O must not block MainActor or liveness")
        var ready = URLRequest(url: base.appendingPathComponent("api/v1/ready"))
        ready.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, readiness) = try await client.data(for: ready)
        precondition((readiness as! HTTPURLResponse).statusCode == 200,
                     "session read readiness is distinct from journal durability")
        release.signal()
        let (_, response) = try await pending.value
        precondition((response as! HTTPURLResponse).statusCode == 200 && acknowledged)
        try await waitForJournalTest { !chat.isStreaming }

        let broken = ChatSession(makeJournal: { id in
            try RunJournal(sessionID: id) { _ in throw CocoaError(.fileWriteOutOfSpace) }
        })
        manager.sessions = [broken]
        broken.submitRemote("! /usr/bin/true")
        try await waitForJournalTest { !broken.isStreaming }
        mutation.url = base.appendingPathComponent("api/v1/sessions/\(broken.id)/metadata")
        let (errorBody, errorResponse) = try await client.data(for: mutation)
        precondition((errorResponse as! HTTPURLResponse).statusCode == 500)
        precondition(String(decoding: errorBody, as: UTF8.self).contains("may have applied"),
                     "failed durability must not return success or invite blind mutation replay")
    }
}
