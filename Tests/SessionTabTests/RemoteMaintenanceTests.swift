import Foundation

extension SessionTabTests {
    @MainActor
    static func testRemoteMaintenance() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("maintenance-tests-\(UUID())")
        let repo = root.appendingPathComponent("checkout with spaces")
        let origin = root.appendingPathComponent("origin")
        let app = repo.appendingPathComponent("Cantrip.app")
        try fm.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try fm.createDirectory(at: origin, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try PropertyListSerialization.data(fromPropertyList: ["CantripBuildIdentity": "built-test"],
            format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try "app:\n\t@printf 'fixture build complete\\n'\n".write(to: repo.appendingPathComponent("Makefile"),
            atomically: true, encoding: .utf8)
        try "Cantrip.app/\n".write(to: repo.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        func git(_ args: [String], in directory: URL) async throws {
            _ = try await RemoteMaintenance.runCommand("/usr/bin/git", args, directory) { _ in }
        }
        try await git(["init", "--bare", "--initial-branch=main"], in: origin)
        try await git(["init", "--initial-branch=main"], in: repo)
        try await git(["config", "user.email", "fixture@example.invalid"], in: repo)
        try await git(["config", "user.name", "Fixture"], in: repo)
        try await git(["add", "."], in: repo)
        try await git(["commit", "-m", "Fixture"], in: repo)
        try await git(["remote", "add", "origin", origin.path], in: repo)
        try await git(["push", "-u", "origin", "main"], in: repo)

        let manager = SessionManager()
        let stateFile = root.appendingPathComponent("state/state.json")
        var builds = 0, restarts = 0, failBuild = false, busyDuringRestart = false
        let runner: RemoteMaintenance.Runner = { executable, arguments, directory, output in
            if executable == "/usr/bin/codesign" {
                if busyDuringRestart { manager.active.isStreaming = true }
                return ""
            }
            if executable == "/usr/bin/make" {
                builds += 1
                await output(String(repeating: "build output\n", count: 2000))
                if failBuild { throw RemoteMaintenanceError(status: 422, message: "Fixture build failure") }
            }
            return try await RemoteMaintenance.runCommand(executable, arguments, directory, output: output)
        }
        let service = RemoteMaintenance(manager: manager, app: app, stateFile: stateFile,
            runningBuild: "old-test", run: runner, restart: { received in
                precondition(received == app)
                restarts += 1
            })
        func wait(_ service: RemoteMaintenance = service) async throws {
            for _ in 0..<1000 {
                if service.snapshot().job?.isRunning != true { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            preconditionFailure("Maintenance operation did not finish")
        }
        func action(_ action: RemoteMaintenanceAction) -> RemoteMaintenanceRequest {
            RemoteMaintenanceRequest(id: UUID(), action: action, revision: service.snapshot().revision)
        }
        let check = action(.check)
        _ = try service.start(check)
        _ = try service.start(check)
        do {
            _ = try service.start(action(.check))
            preconditionFailure("Concurrent jobs must fail")
        } catch let error as RemoteMaintenanceError { precondition(error.status == 409) }
        try await wait()
        precondition(service.snapshot().commitsBehind == 0 && service.snapshot().localChanges == false)
        precondition(service.snapshot().job?.phase == "succeeded")

        manager.active.isPrivate = true
        manager.active.isStreaming = true
        do {
            _ = try service.start(action(.restart))
            preconditionFailure("Private busy tabs must block restart too")
        } catch let error as RemoteMaintenanceError { precondition(error.status == 409) }
        precondition(service.snapshot().busySessions > 0)
        manager.active.isStreaming = false
        manager.active.isPrivate = false

        let edit = repo.appendingPathComponent("local.txt")
        try "Keep this local work".write(to: edit, atomically: true, encoding: .utf8)
        _ = try service.start(action(.update))
        try await wait()
        precondition(service.snapshot().job?.phase == "failed" && builds == 0)
        let preserved = try String(contentsOf: edit, encoding: .utf8)
        precondition(preserved == "Keep this local work")
        let rebuild = action(.rebuild)
        _ = try service.start(rebuild)
        try await wait()
        precondition(builds == 1 && restarts == 0)
        precondition(service.snapshot().job?.output.count ?? 0 <= 16_000)
        precondition(service.snapshot().job?.phase == "succeeded")
        _ = try service.start(rebuild)
        precondition(builds == 1, "The same accepted request is never rebuilt")
        let recovered = RemoteMaintenance(manager: manager, app: app, stateFile: stateFile,
            runningBuild: "old-test", run: runner, restart: { _ in restarts += 1 })
        _ = try recovered.start(rebuild)
        precondition(builds == 1, "Deduplication survives host restart")
        do {
            _ = try recovered.start(RemoteMaintenanceRequest(id: rebuild.id, action: .update, revision: rebuild.revision))
            preconditionFailure("An ID cannot be reused for a different action")
        } catch let error as RemoteMaintenanceError { precondition(error.status == 409) }

        failBuild = true
        _ = try service.start(action(.rebuild))
        try await wait()
        precondition(service.snapshot().job?.message == "Fixture build failure" && restarts == 0)
        failBuild = false
        try fm.removeItem(at: edit)
        let producer = root.appendingPathComponent("publisher")
        try await git(["clone", origin.path, producer.path], in: root)
        try await git(["config", "user.email", "fixture@example.invalid"], in: producer)
        try await git(["config", "user.name", "Fixture"], in: producer)
        try "New upstream code".write(to: producer.appendingPathComponent("upstream.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "."], in: producer)
        try await git(["commit", "-m", "Upstream update"], in: producer)
        try await git(["push"], in: producer)
        _ = try service.start(action(.update))
        try await wait()
        precondition(service.snapshot().job?.phase == "succeeded" && builds == 3)
        let updatedSource = try String(contentsOf: repo.appendingPathComponent("upstream.txt"), encoding: .utf8)
        precondition(updatedSource == "New upstream code", "Update must actually fast-forward to fetched source")
        try "Unpublished local commit".write(to: repo.appendingPathComponent("local.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "."], in: repo)
        try await git(["commit", "-m", "Local work"], in: repo)
        try "Another upstream update".write(to: producer.appendingPathComponent("upstream.txt"), atomically: true, encoding: .utf8)
        try await git(["add", "."], in: producer)
        try await git(["commit", "-m", "Divergent update"], in: producer)
        try await git(["push"], in: producer)
        _ = try service.start(action(.update))
        try await wait()
        precondition(service.snapshot().job?.phase == "failed" && builds == 3,
                     "Diverged history must fail without merging, rebasing, or building")
        do {
            _ = try service.start(RemoteMaintenanceRequest(id: UUID(), action: .rebuild, revision: check.revision))
            preconditionFailure("A stale revision cannot start new work, even if its receipt was evicted")
        } catch let error as RemoteMaintenanceError { precondition(error.status == 409) }

        busyDuringRestart = true
        _ = try service.start(action(.restart))
        try await wait()
        precondition(restarts == 0 && service.snapshot().job?.phase == "failed",
                     "Recheck activity after asynchronous restart preparation")
        manager.active.isStreaming = false
        busyDuringRestart = false
        let restartRequest = action(.restart)
        _ = try service.start(restartRequest)
        for _ in 0..<400 {
            if restarts == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(restarts == 1)
        let restarted = RemoteMaintenance(manager: manager, app: app, stateFile: stateFile,
            runningBuild: "built-test", run: runner, restart: { _ in restarts += 1 })
        precondition(restarted.snapshot().job?.phase == "succeeded")
        _ = try restarted.start(restartRequest)
        precondition(restarts == 1)

        let server = RemoteControlServer(manager: manager, maintenance: restarted)
        let port = Int.random(in: 49152...65535), token = UUID().uuidString
        server.start(port: port, token: token)
        defer { server.stop() }
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        try await Task.sleep(for: .milliseconds(300))
        func request(method: String = "GET", body: String? = nil, auth: Bool = true) async throws -> Int {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/maintenance")!)
            request.httpMethod = method
            request.httpBody = body.map { Data($0.utf8) }
            if auth { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (_, response) = try await client.data(for: request)
            return (response as! HTTPURLResponse).statusCode
        }
        let unauthenticated = try await request(auth: false)
        let unsupported = try await request(method: "DELETE")
        let invalid = try await request(method: "POST", body: #"{"id":"bad","action":"rebuild"}"#)
        let extra = try await request(method: "POST",
            body: #"{"id":"00000000-0000-0000-0000-000000000001","action":"rebuild","command":"arbitrary"}"#)
        let read = try await request()
        let accepted = try await request(method: "POST",
            body: #"{"id":"00000000-0000-0000-0000-000000000001","action":"check","revision":"\#(restarted.snapshot().revision)"}"#)
        precondition(unauthenticated == 401 && unsupported == 405 && invalid == 400 && extra == 400)
        precondition(read == 200 && accepted == 202)
        try await wait(restarted)
        print("Remote maintenance: paired actions, local edits, bounded output, durable dedup, and safe restart passed")
    }
}
