import Darwin
import Foundation

private final class WaitFakeBackend: Backend {
    var messages: [String] = []
    var sink: ((BackendEvent) -> Void)?

    func send(_ request: BackendRequest, workdir: String, onEvent: @escaping (BackendEvent) -> Void) {
        messages.append(request.userMessage)
        sink = onEvent
        DispatchQueue.main.async { onEvent(.done) }
    }
    func cancel() {}
    func reset() {}
}

extension SessionTabTests {
    /// `cantrip schedule wait` end to end (docs/cantrip-home.md "Upcoming"): real waiters started the way the CLI starts
    /// them, registered through the CLI's request. A cancelled wait wakes nobody and one registered right after it is
    /// listed until its condition holds, then wakes its tab with the exit status and output. A waiter outlives the tab
    /// runtime that started it (an idle-stop), a waiter that scheduled its own step isn't followed by a second wake, one
    /// past its deadline is stopped and reported, and one that ended while Cantrip wasn't running is reported at launch.
    /// Each registration, end and delivery is in Cantrip.log.
    @MainActor
    static func testUpcomingWaits() async throws {
        let homeChat = ChatSession(id: ChatSession.cantripHomeID, copilotBackend: WaitFakeBackend(),
                                   makeJournal: { _ in try RunJournal(sessionID: UUID()) })
        let manager = SessionManager(homeSession: homeChat, homeBackgroundSession: ChatSession(
            id: ChatSession.cantripHomeBackgroundID, copilotBackend: WaitFakeBackend(),
            makeJournal: { _ in try RunJournal(sessionID: UUID()) }))
        let settings = AppSettings.shared
        let savedBackend = (settings.backend, settings.memoryEnabled)
        (settings.backend, settings.memoryEnabled) = (.copilot, false)
        BackendLimitTracker.shared.clear()
        defer { (settings.backend, settings.memoryEnabled) = savedBackend }
        let backend = WaitFakeBackend()
        let tab = try manager.addTab(ChatSession(copilotBackend: backend), inSection: nil)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("upcoming-waits-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = UpcomingStore(url: folder.appendingPathComponent("upcoming.json"))
        var upcoming = HomeUpcoming()
        upcoming.store = store
        upcoming.start(manager: manager)
        var started: [Int32] = []
        defer {
            upcoming.stop()
            for pid in started { kill(-pid, SIGKILL) }
            try? FileManager.default.removeItem(at: folder)
        }

        func flag(_ name: String) -> String { folder.appendingPathComponent(name).path }
        /// A waiter that prints and exits 0 once `name` exists.
        func script(_ name: String) -> String {
            "while [ ! -e '\(flag(name))' ]; do sleep 0.1; done; echo 'condition \(name) matched'"
        }
        func register(_ pid: Int32, _ output: String, _ status: String, title: String,
                      until: Date? = nil) throws -> String {
            started.append(pid)
            var request: [String: Any] = ["action": "wait", "title": title, "pid": Int(pid), "output": output,
                                          "status": status, "ownGroup": true, "tab": tab.id.uuidString]
            request["until"] = until?.timeIntervalSince1970
            let reply = upcoming.handle(request)
            guard let id = reply["id"] as? String else { preconditionFailure("registering failed: \(reply)") }
            return id
        }
        func start(_ name: String, title: String, until: Date? = nil) throws -> (id: String, pid: Int32) {
            let waiter = try CantripCLI.startWaiter(["/bin/sh", "-c", script(name)])
            return (try register(waiter.pid, waiter.output, waiter.status, title: title, until: until), waiter.pid)
        }
        func listed() -> String { upcoming.handle(["action": "list"])["text"] as? String ?? "" }
        /// Reaps a waiter this process started itself (the CLI exits, so launchd reaps real ones).
        func running(_ pid: Int32) -> Bool {
            var status: Int32 = 0
            _ = waitpid(pid, &status, WNOHANG)
            return HomeUpcoming.processStart(pid) != nil
        }
        func finish(_ name: String, _ pid: Int32) async throws {
            FileManager.default.createFile(atPath: flag(name), contents: nil)
            try await waitForJournalTest { !running(pid) }
        }
        func log() -> String { (try? String(contentsOf: Log.fileURL, encoding: .utf8)) ?? "" }
        func expectWakes(_ count: Int, line: UInt = #line) async throws {
            let deadline = Date().addingTimeInterval(10)
            while backend.messages.count < count, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            precondition(backend.messages.count >= count, """
                line \(line): \(backend.messages.count) wakes, want \(count); tab messages \(tab.messages.map { "\($0.role): \($0.text.prefix(80))" }), \
                queued \(tab.queued.count), streaming \(tab.isStreaming)
                \(log().split(separator: "\n").filter { $0.contains("upcoming:") }.joined(separator: "\n"))
                """)
        }

        // Cancel, then register a new wait at once: the new one stays listed and wakes the tab, the old one doesn't.
        let first = try start("first", title: "Waits for the first thing")
        precondition(listed().contains(first.id))
        precondition((upcoming.handle(["action": "cancel", "id": first.id])["text"] as? String ?? "").hasPrefix("Stopped"))
        let second = try start("second", title: "Waits for the second thing")
        try await waitForJournalTest { !running(first.pid) }
        upcoming.tick()
        precondition(!listed().contains(first.id) && listed().contains(second.id), "the re-registered wait stays listed: \(listed())")
        precondition(backend.messages.isEmpty, "a cancelled wait wakes nobody")
        try await finish("second", second.pid)
        upcoming.tick()
        try await expectWakes(1)
        let woken = backend.messages[0]
        precondition(woken.contains("your wait “Waits for the second thing” ended: process \(second.pid) exited with status 0")
                     && woken.contains("condition second matched"), woken)
        precondition(!listed().contains(second.id))

        // A waiter outlives the tab runtime that started it (an idle-stop ends that runtime).
        let marker = flag("runtime.out")
        let runtime = Process()
        runtime.executableURL = URL(fileURLWithPath: "/bin/sh")
        runtime.arguments = ["-c", #""$0" > "$1"; exec sleep 600"#, Bundle.main.executableURL!.path, marker]
        var environment = ProcessInfo.processInfo.environment
        environment["CANTRIP_TEST_START_WAITER"] = script("third")
        environment.removeValue(forKey: "CANTRIP_TAB_TEST_ONLY")
        runtime.environment = environment
        try runtime.run()
        try await waitForJournalTest(timeout: 15) {
            ((try? String(contentsOfFile: marker, encoding: .utf8)) ?? "").split(separator: "\t").count == 3
        }
        let fields = try String(contentsOfFile: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t").map(String.init)
        let third = (id: try register(Int32(fields[0])!, fields[1], fields[2], title: "Waits across an idle-stop"),
                     pid: Int32(fields[0])!)
        runtime.terminate()
        runtime.waitUntilExit()
        upcoming.tick()
        precondition(running(third.pid) && listed().contains(third.id), "the wait outlives the runtime that started it")
        try await finish("third", third.pid)
        upcoming.tick()
        try await expectWakes(2)
        precondition(backend.messages[1].contains("“Waits across an idle-stop” ended") && backend.messages[1].contains("condition third matched"))

        // A waiter that scheduled its own follow-up step: no second wake.
        let fourth = try start("fourth", title: "Waits, then schedules its own step")
        let step = upcoming.handle(["action": "add", "at": Date().addingTimeInterval(3_600).timeIntervalSince1970,
                                    "title": "Its own follow-up", "message": "Check it", "tab": tab.id.uuidString,
                                    "ancestors": [Int(getpid()), Int(fourth.pid)]])
        let stepID = try requireHome(step["id"] as? String)
        try await finish("fourth", fourth.pid)
        upcoming.tick()
        try await waitForJournalTest { log().contains("its waiter scheduled step \(stepID.dropFirst(5).prefix(8)) itself") }
        precondition(backend.messages.count == 2, "the waiter's own step is its follow-up")
        _ = upcoming.handle(["action": "cancel", "id": stepID])

        // Past its deadline (and the grace for its own give-up): stopped, and the tab told.
        let fifth = try start("never", title: "Waits past its deadline", until: Date().addingTimeInterval(1))
        upcoming.now = { Date().addingTimeInterval(HomeUpcoming.deadlineGrace + 5) }
        upcoming.tick()
        upcoming.now = Date.init
        try await expectWakes(3)
        try await waitForJournalTest { !running(fifth.pid) }
        precondition(backend.messages[2].contains("“Waits past its deadline” ended: it was still waiting at its deadline"))

        // Waits survive a relaunch; one that ended while Cantrip wasn't running is reported at launch.
        let sixth = try start("sixth", title: "Waits across a relaunch")
        upcoming.stop()
        try await finish("sixth", sixth.pid)
        upcoming = HomeUpcoming()
        upcoming.store = store
        upcoming.start(manager: manager)
        try await expectWakes(4)
        precondition(backend.messages[3].contains("“Waits across a relaunch” ended: process \(sixth.pid) exited with status 0"))
        let seventh = try start("seventh", title: "Still listed after a relaunch")
        upcoming.stop()
        upcoming = HomeUpcoming()
        upcoming.store = store
        upcoming.start(manager: manager)
        precondition(listed().contains(seventh.id), "a running wait is still listed after a relaunch")
        try await finish("seventh", seventh.pid)
        upcoming.tick()
        try await expectWakes(5)

        let short = { (id: String) in String(id.dropFirst(5).prefix(8)) }
        try await waitForJournalTest {
            let text = log()
            return [first, second, third, fifth, sixth, seventh].allSatisfy { text.contains("registered wait \(short($0.id)) (process \($0.pid), tab ") }
                && text.contains("stopped registered wait \(short(first.id)) (process \(first.pid)); cancelled, so no tab is woken")
                && text.contains("wait \(short(second.id)) ended: process \(second.pid) exited with status 0")
                && text.contains("delivered the end of wait \(short(second.id)) to its tab")
                && text.contains("wait \(short(fifth.id)) passed its deadline")
        }
        if ProcessInfo.processInfo.environment["CANTRIP_TEST_PRINT_UPCOMING_LOG"] == "1" {
            print(log().split(separator: "\n").filter { $0.contains("upcoming:") }.joined(separator: "\n"))
        }
        print("Upcoming waits: cancel + re-register, outliving the runtime, own follow-up, deadline, relaunch, logged and woken passed")
    }
}
