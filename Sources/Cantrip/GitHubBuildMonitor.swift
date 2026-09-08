import Foundation

struct GitHubBuildTarget: Codable, Equatable {
    let repository: String
    let app: String
    let runner: String

    static func load(from url: URL) throws -> [Self] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw GitHubBuildError.message("Configure github-builds.json on the Cantrip Mac. See Cantrip's GitHub Builds setup.")
        }
        let targets = try JSONDecoder().decode([Self].self, from: Data(contentsOf: url))
        guard !targets.isEmpty, targets.count <= 20,
              Set(targets.map { $0.repository.lowercased() }).count == targets.count,
              targets.allSatisfy({
                  $0.repository.range(of: #"^[A-Za-z0-9_-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
                      && ![".", ".."].contains(String($0.repository.split(separator: "/").last ?? ""))
                      && !$0.app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && !$0.runner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }) else {
            throw GitHubBuildError.message("github-builds.json needs 1-20 unique owner/repository entries, each with an app and runner name.")
        }
        return targets
    }
}

struct GitHubBuildJob: Codable {
    let id: String
    let workflow: String
    let title: String
    let number: Int
    let attempt: Int
    let branch: String
    let commit: String
    let status: String
    let job: String
    let step: String?
    let createdAt: String
    let startedAt: String?
    let url: String
    // Only "assigned" means GitHub has selected this runner.
    let assignment: String
}

struct GitHubBuildRepository: Codable {
    let repository: String
    let app: String
    let runner: String
    var runnerStatus: String = "unknown"
    var busy: Bool = false
    var checkedAt: String?
    var jobs: [GitHubBuildJob] = []
    var warning: String?
}

struct GitHubBuildSnapshot: Codable {
    var repositories: [GitHubBuildRepository] = []
    var isRefreshing = false
    var error: String?
}

enum GitHubBuildError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

struct GitHubActionsAPI {
    let get: (String) async throws -> Data

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration)
    }()

    static func authenticated() async throws -> Self {
        let token = try await tokenFromCLI()
        return Self { path in
            guard let url = URL(string: "https://api.github.com/\(path)") else {
                throw GitHubBuildError.message("Invalid GitHub API path.")
            }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("Cantrip-Build-Monitor", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw GitHubBuildError.message("GitHub returned an invalid response.")
            }
            guard response.statusCode == 200 else {
                let message: String
                switch response.statusCode {
                case 401: message = "Sign in again with gh auth login on the Cantrip Mac."
                case 403, 429: message = "GitHub denied access or rate-limited this request. Check Actions read and runner administration read permissions, then retry."
                case 404: message = "Repository or runner access is unavailable. Check the configured repository and GitHub permissions."
                default: message = "GitHub returned HTTP \(response.statusCode)."
                }
                throw GitHubBuildError.message(message)
            }
            return data
        }
    }

    private static func tokenFromCLI() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let paths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
                guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                    continuation.resume(throwing: GitHubBuildError.message("Install GitHub CLI and run gh auth login on the Cantrip Mac."))
                    return
                }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = ["auth", "token", "--hostname", "github.com"]
                process.standardInput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                let output = Pipe()
                process.standardOutput = output
                do {
                    try process.run()
                    let deadline = Date().addingTimeInterval(5)
                    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
                    guard !process.isRunning else {
                        process.terminate()
                        throw GitHubBuildError.message("GitHub login lookup timed out on the Mac.")
                    }
                    let token = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard process.terminationStatus == 0, !token.isEmpty else {
                        throw GitHubBuildError.message("Run gh auth login on the Cantrip Mac to read GitHub builds.")
                    }
                    continuation.resume(returning: token)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func collect(_ target: GitHubBuildTarget) async throws -> GitHubBuildRepository {
        let root = "repos/\(target.repository)/actions"
        let runners: [Runner] = try await pages("\(root)/runners", key: "runners")
        guard let runner = runners.first(where: { $0.name == target.runner }) else {
            throw GitHubBuildError.message("Runner \(target.runner) was not found for this repository.")
        }
        var runsByID: [Int64: Run] = [:]
        for status in ["in_progress", "queued", "waiting", "pending", "requested"] {
            let runs: [Run] = try await pages("\(root)/runs?status=\(status)", key: "workflow_runs")
            for run in runs { runsByID[run.id] = run }
        }
        guard runsByID.count <= 100 else {
            throw GitHubBuildError.message("More than 100 active workflows; this repository's queue is too large to monitor completely.")
        }
        var jobs: [GitHubBuildJob] = []
        for run in runsByID.values.sorted(by: { $0.id < $1.id }) {
            let runJobs: [Job] = try await pages("\(root)/runs/\(run.id)/attempts/\(run.run_attempt)/jobs", key: "jobs")
            let unfinished = runJobs.filter { $0.status != "completed" }
            for job in unfinished where job.matches(runner) {
                jobs.append(run.snapshot(
                    id: "\(target.repository)/job/\(job.id)", status: job.status,
                    job: job.name, step: job.steps?.first(where: { $0.status == "in_progress" })?.name,
                    startedAt: job.started_at, url: job.html_url,
                    assignment: (job.runner_id ?? 0) > 0 ? "assigned" : "eligible"
                ))
            }
            // GitHub may withhold jobs during approval or concurrency waits.
            // Keep these separate from jobs known to be eligible for our runner.
            let unknownEligibility = unfinished.contains { ($0.runner_id ?? 0) == 0 && $0.labels.isEmpty }
            if (unfinished.isEmpty || unknownEligibility) && run.status != "completed" {
                jobs.append(run.snapshot(
                    id: "\(target.repository)/run/\(run.id)", status: run.status,
                    job: "Waiting for workflow jobs", assignment: "workflow"
                ))
            }
            guard jobs.count <= 500 else {
                throw GitHubBuildError.message("More than 500 active jobs; this repository's queue is too large to display completely.")
            }
        }
        var result = GitHubBuildRepository(repository: target.repository, app: target.app, runner: target.runner)
        result.runnerStatus = runner.status
        result.busy = runner.busy
        result.jobs = jobs.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        result.checkedAt = ISO8601DateFormatter().string(from: Date())
        return result
    }

    private func pages<T: Decodable>(_ path: String, key: String) async throws -> [T] {
        var result: [T] = []
        for page in 1...10 {
            let data = try await get("\(path)\(path.contains("?") ? "&" : "?")per_page=100&page=\(page)")
            let envelope = try JSONDecoder().decode(Page<T>.self, from: data)
            let items: [T]
            switch key {
            case "runners": items = envelope.runners ?? []
            case "workflow_runs": items = envelope.workflow_runs ?? []
            default: items = envelope.jobs ?? []
            }
            guard envelope.total_count >= 0,
                  (key != "runners" || envelope.runners != nil),
                  (key != "workflow_runs" || envelope.workflow_runs != nil),
                  (key != "jobs" || envelope.jobs != nil) else {
                throw GitHubBuildError.message("GitHub returned an incomplete build response.")
            }
            result += items
            if result.count >= envelope.total_count { return result }
            if items.count < 100 {
                throw GitHubBuildError.message("GitHub's build list changed during pagination. The last snapshot is retained; retry on the next refresh.")
            }
        }
        throw GitHubBuildError.message("More than 1,000 GitHub results; this repository's queue cannot be shown completely.")
    }

    private struct Page<T: Decodable>: Decodable {
        let total_count: Int
        let runners: [T]?
        let workflow_runs: [T]?
        let jobs: [T]?
    }

    struct Runner: Decodable {
        let id: Int64
        let name: String
        let status: String
        let busy: Bool
        let labels: [Label]
        struct Label: Decodable { let name: String }
    }

    private struct Run: Decodable {
        let id: Int64
        let name: String?
        let display_title: String
        let run_number: Int
        let run_attempt: Int
        let head_branch: String?
        let head_sha: String
        let status: String
        let created_at: String
        let html_url: String

        func snapshot(id: String, status: String, job: String, step: String? = nil,
                      startedAt: String? = nil, url: String? = nil, assignment: String) -> GitHubBuildJob {
            GitHubBuildJob(id: id, workflow: name ?? "Workflow", title: display_title,
                number: run_number, attempt: run_attempt, branch: head_branch ?? "Detached HEAD",
                commit: head_sha, status: status, job: job, step: step,
                createdAt: created_at, startedAt: startedAt, url: url ?? html_url,
                assignment: assignment)
        }
    }

    struct Job: Decodable {
        let id: Int64
        let name: String
        let status: String
        let runner_id: Int64?
        let labels: [String]
        let started_at: String?
        let html_url: String
        let steps: [Step]?
        struct Step: Decodable { let name: String; let status: String }

        func matches(_ runner: Runner) -> Bool {
            if let runner_id, runner_id > 0 { return runner_id == runner.id }
            let required = Set(labels.map { $0.lowercased() })
            return !required.isEmpty && required.isSubset(of: Set(runner.labels.map { $0.name.lowercased() }))
        }
    }
}

actor GitHubBuildMonitor {
    static let configurationURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/Cantrip/github-builds.json")
    private let configurationURL: URL
    private let makeAPI: () async throws -> GitHubActionsAPI
    private let refreshInterval: TimeInterval
    private var value = GitHubBuildSnapshot()
    private var lastStarted: Date?

    init(configurationURL: URL = GitHubBuildMonitor.configurationURL,
         refreshInterval: TimeInterval = 60,
         makeAPI: @escaping () async throws -> GitHubActionsAPI = { try await .authenticated() }) {
        self.configurationURL = configurationURL
        self.refreshInterval = refreshInterval
        self.makeAPI = makeAPI
    }

    func snapshot() -> GitHubBuildSnapshot {
        if !value.isRefreshing && (lastStarted.map { Date().timeIntervalSince($0) >= refreshInterval } ?? true) {
            value.isRefreshing = true
            lastStarted = Date()
            Task { await refresh() }
        }
        return value
    }

    private func refresh() async {
        defer { value.isRefreshing = false }
        do {
            let targets = try GitHubBuildTarget.load(from: configurationURL)
            value.repositories = targets.map { target in
                value.repositories.first(where: {
                    $0.repository == target.repository && $0.runner == target.runner && $0.app == target.app
                }) ?? GitHubBuildRepository(repository: target.repository, app: target.app, runner: target.runner)
            }
            let api = try await makeAPI()
            value.error = nil
            // Bound cross-repository requests; readers always get an immediate
            // cached snapshot, never a GitHub call on Remote's request path.
            await withTaskGroup(of: GitHubBuildRepository.self) { group in
                var next = 0
                func enqueue(_ target: GitHubBuildTarget) {
                    let previous = value.repositories.first { $0.repository == target.repository }!
                    group.addTask {
                        do { return try await api.collect(target) }
                        catch {
                            var failed = previous
                            failed.warning = error.localizedDescription
                            return failed
                        }
                    }
                }
                while next < min(3, targets.count) { enqueue(targets[next]); next += 1 }
                for await result in group {
                    if let index = value.repositories.firstIndex(where: { $0.repository == result.repository }) {
                        value.repositories[index] = result
                    }
                    if next < targets.count { enqueue(targets[next]); next += 1 }
                }
            }
        } catch {
            value.error = error.localizedDescription
        }
    }
}
