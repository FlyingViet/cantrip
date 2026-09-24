import AppKit
import Foundation

struct RemoteMaintenanceError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

enum RemoteMaintenanceAction: String, Codable {
    case check, update, rebuild, restart
}

struct RemoteMaintenanceRequest: Codable, Equatable {
    let id: UUID
    let action: RemoteMaintenanceAction
    let revision: UUID
}

struct RemoteMaintenanceJob: Codable {
    let request: RemoteMaintenanceRequest
    var phase: String
    var message: String
    var output = ""
    let startedAt: Date
    var finishedAt: Date?

    var isRunning: Bool { finishedAt == nil }
}

struct RemoteMaintenanceSnapshot: Encodable {
    let revision: UUID
    let available: Bool
    let unavailableReason: String?
    let runningBuild: String
    let installedBuild: String?
    let busySessions: Int
    let branch: String?
    let localChanges: Bool?
    let commitsBehind: Int?
    let checkedAt: Date?
    let job: RemoteMaintenanceJob?
    let acceptedRequestIDs: [UUID]
}

/// Fixed, paired-host actions. Jobs belong to the Mac, not to a phone connection.
@MainActor
final class RemoteMaintenance {
    typealias Runner = @MainActor (String, [String], URL, @escaping @Sendable (String) async -> Void) async throws -> String
    private struct State: Codable {
        var revision = UUID()
        var job: RemoteMaintenanceJob?
        var requests: [RemoteMaintenanceRequest] = []
        var expectedBuild: String?
    }

    private weak var manager: SessionManager?
    private let repository: URL
    private let app: URL
    private let stateFile: URL
    private let runningBuild: String
    private let run: Runner
    private let restart: @MainActor (URL) throws -> Void
    private var state = State()
    private var loadError: String?
    private var branch: String?
    private var localChanges: Bool?
    private var commitsBehind: Int?
    private var checkedAt: Date?
    private var worker: Task<Void, Never>?

    init(manager: SessionManager, app: URL = Bundle.main.bundleURL,
         stateFile: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/Cantrip/maintenance/state.json"),
         runningBuild: String = CrashRecovery.buildIdentity,
         run: @escaping Runner = RemoteMaintenance.runCommand,
         restart: @escaping @MainActor (URL) throws -> Void = RemoteMaintenance.relaunch) {
        self.manager = manager
        self.app = app
        repository = app.deletingLastPathComponent()
        self.stateFile = stateFile
        self.runningBuild = runningBuild
        self.run = run
        self.restart = restart
        do {
            if FileManager.default.fileExists(atPath: stateFile.path) {
                state = try JSONDecoder().decode(State.self, from: Data(contentsOf: stateFile))
                if state.job?.isRunning == true {
                    let restarted = state.job?.phase == "restarting" && state.expectedBuild == runningBuild
                    state.job?.phase = restarted ? "succeeded" : "failed"
                    state.job?.message = restarted ? "Cantrip restarted successfully."
                        : "The Mac app exited before this operation completed. Inspect the checkout before retrying."
                    state.job?.finishedAt = Date()
                    try save()
                }
            }
        } catch {
            loadError = "Could not recover maintenance state: \(error.localizedDescription)"
            Log.write("remote-maintenance: \(loadError!)")
        }
    }

    private var unavailableReason: String? {
        if let loadError { return loadError }
        guard app.lastPathComponent == "Cantrip.app",
              FileManager.default.fileExists(atPath: repository.appendingPathComponent(".git").path),
              FileManager.default.fileExists(atPath: repository.appendingPathComponent("Makefile").path) else {
            return "Run Cantrip.app from its source checkout on the Mac to enable remote builds."
        }
        return nil
    }

    private var busySessions: Int {
        manager?.sessions.filter { $0.isStreaming || !$0.queued.isEmpty || $0.shell.isRunning }.count ?? 0
    }

    private var installedBuild: String? {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return info["CantripBuildIdentity"] as? String
    }

    func snapshot() -> RemoteMaintenanceSnapshot {
        RemoteMaintenanceSnapshot(revision: state.revision, available: unavailableReason == nil,
            unavailableReason: unavailableReason, runningBuild: runningBuild,
            installedBuild: installedBuild, busySessions: busySessions,
            branch: branch, localChanges: localChanges, commitsBehind: commitsBehind,
            checkedAt: checkedAt, job: state.job, acceptedRequestIDs: state.requests.map(\.id))
    }

    func start(_ request: RemoteMaintenanceRequest) throws -> RemoteMaintenanceSnapshot {
        if let reason = unavailableReason { throw RemoteMaintenanceError(status: 503, message: reason) }
        if let prior = state.requests.first(where: { $0.id == request.id }) {
            guard prior == request else {
                throw RemoteMaintenanceError(status: 409, message: "This request ID was already used for another action.")
            }
            return snapshot()
        }
        // An evicted receipt must never turn an old retry into a new operation.
        guard request.revision == state.revision else {
            throw RemoteMaintenanceError(status: 409, message: "Maintenance status changed. Refresh before starting a new action.")
        }
        guard state.job?.isRunning != true else {
            throw RemoteMaintenanceError(status: 409, message: "A maintenance operation is already running. Refresh its progress.")
        }
        if request.action != .check { try requireIdle() }
        let previous = state
        state.revision = UUID()
        state.requests = Array((state.requests + [request]).suffix(64))
        state.expectedBuild = nil
        state.job = RemoteMaintenanceJob(request: request, phase: "starting",
            message: "Preparing \(request.action.rawValue)...", startedAt: Date())
        do { try save() }
        catch { state = previous; throw error }
        worker = Task {
            do {
                try await execute(request.action)
            } catch {
                state.job?.phase = "failed"
                state.job?.message = error.localizedDescription
                state.job?.finishedAt = Date()
                Log.write("remote-maintenance: \(error.localizedDescription)")
                do { try save() }
                catch {
                    loadError = "Could not save maintenance result: \(error.localizedDescription)"
                    Log.write("remote-maintenance: \(loadError!)")
                }
            }
            worker = nil
        }
        return snapshot()
    }

    private func requireIdle() throws {
        guard manager != nil, busySessions == 0 else {
            throw RemoteMaintenanceError(status: 409,
                message: "Wait for all Mac tabs, queued prompts, and shell commands to finish. No work has been stopped.")
        }
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(state).write(to: stateFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateFile.path)
    }

    private func phase(_ phase: String, _ message: String, finished: Bool = false) throws {
        state.job?.phase = phase
        state.job?.message = message
        if finished { state.job?.finishedAt = Date() }
        try save()
    }

    @discardableResult
    private func command(_ executable: String, _ arguments: [String], showOutput: Bool = false) async throws -> String {
        try await run(executable, arguments, repository) { [weak self] chunk in
            guard showOutput else { return }
            await self?.appendOutput(chunk)
        }
    }

    private func appendOutput(_ chunk: String) {
        let output = String(((state.job?.output ?? "") + chunk).suffix(16_000))
        state.job?.output = output
    }

    @discardableResult
    private func git(_ arguments: [String]) async throws -> String {
        try await command("/usr/bin/git", arguments).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func inspect() async throws {
        branch = try await git(["branch", "--show-current"])
        localChanges = try await git(["status", "--porcelain", "--untracked-files=normal"]).isEmpty == false
    }

    private func execute(_ action: RemoteMaintenanceAction) async throws {
        if action == .restart {
            guard let expected = installedBuild else {
                throw RemoteMaintenanceError(status: 409, message: "Build Cantrip on the Mac before restarting.")
            }
            try await command("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
            state.expectedBuild = expected
            try phase("restarting", "Restart requested. AgentGateway will reconnect when the Mac is ready.")
            try await Task.sleep(for: .seconds(2))
            guard let manager else { throw RemoteMaintenanceError(status: 503, message: "Session manager unavailable.") }
            for session in manager.sessions { try await session.flushJournal() }
            // Check again after every suspension point: a local tab may have started meanwhile.
            try requireIdle()
            guard installedBuild == expected else {
                throw RemoteMaintenanceError(status: 409, message: "The installed build changed. Refresh before restarting.")
            }
            try restart(app)
            return
        }

        try phase("checking", "Inspecting the Mac checkout...")
        try await inspect()
        if action == .check || action == .update {
            if action == .update { try requireCleanMain() }
            try phase("checking", "Fetching updates from origin/main...")
            try await git(["fetch", "--quiet", "origin", "main"])
            let count = try await git(["rev-list", "--count", "HEAD..origin/main"])
            guard let count = Int(count) else {
                throw RemoteMaintenanceError(status: 500, message: "Git returned an invalid update count.")
            }
            commitsBehind = count
            checkedAt = Date()
        }
        if action == .check {
            try phase("succeeded", "\(commitsBehind ?? 0) newer commit(s) on origin/main.", finished: true)
            return
        }
        if action == .update {
            try await inspect()
            try requireCleanMain()
            try requireIdle()
            try phase("updating", "Fast-forwarding main. Local edits will not be stashed or discarded.")
            try await git(["merge", "--ff-only", "--no-edit", "origin/main"])
            commitsBehind = 0
        }
        guard try await git(["diff", "--name-only", "--diff-filter=U"]).isEmpty else {
            throw RemoteMaintenanceError(status: 409, message: "Resolve merge conflicts on the Mac before rebuilding.")
        }
        try requireIdle()
        try phase("building", "Building and signing Cantrip. The current app stays open.")
        try await command("/usr/bin/make", ["app"], showOutput: true)
        guard installedBuild != nil else {
            throw RemoteMaintenanceError(status: 500, message: "The build did not produce a Cantrip app with a build identity.")
        }
        try phase("succeeded", "Build ready. Restart Cantrip when all tabs are idle to activate it.", finished: true)
    }

    private func requireCleanMain() throws {
        guard branch == "main", localChanges == false else {
            throw RemoteMaintenanceError(status: 409,
                message: "Update requires a clean main branch. Commit or resolve local changes on the Mac, or use Rebuild Current Source without pulling.")
        }
    }

    nonisolated static func runCommand(_ executable: String, _ arguments: [String], _ directory: URL,
                                      output: @escaping @Sendable (String) async -> Void) async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = directory
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            environment["GIT_TERMINAL_PROMPT"] = "0"
            environment["GIT_SSH_COMMAND"] = "/usr/bin/ssh -oBatchMode=yes -oConnectTimeout=15"
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            pipe.fileHandleForWriting.closeFile()
            defer { pipe.fileHandleForReading.closeFile() }
            var tail = Data()
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                tail.append(chunk)
                if tail.count > 32_768 { tail = tail.suffix(32_768) }
                await output(String(decoding: chunk, as: UTF8.self))
            }
            process.waitUntilExit()
            let text = String(decoding: tail, as: UTF8.self)
            guard process.terminationStatus == 0 else {
                throw RemoteMaintenanceError(status: 422,
                    message: "\(URL(fileURLWithPath: executable).lastPathComponent) failed (\(process.terminationStatus)). \(text.suffix(2000))")
            }
            return text
        }.value
    }

    static func relaunch(_ app: URL) throws {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for this exact process to exit; never kill another Cantrip instance.
        helper.arguments = ["-c", """
            for attempt in $(/usr/bin/seq 1 60); do
                if ! /bin/kill -0 "$1" 2>/dev/null; then
                    exec /usr/bin/open -n "$2"
                fi
                /bin/sleep 1
            done
            echo "Cantrip did not exit within 60 seconds." >&2
            exit 1
            """, "cantrip-restart", String(ProcessInfo.processInfo.processIdentifier), app.path]
        let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Cantrip-restart.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            guard FileManager.default.createFile(atPath: logURL.path, contents: nil,
                                                attributes: [.posixPermissions: 0o600]) else {
                throw RemoteMaintenanceError(status: 500, message: "Could not create the restart log on the Mac.")
            }
        }
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        try log.seekToEnd()
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = log
        helper.standardError = log
        try helper.run()
        NSApplication.shared.terminate(nil)
    }
}
