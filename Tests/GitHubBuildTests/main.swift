import Foundation

private actor Fixture {
    var calls: [String] = []
    var failing = false
    var paginate = false
    var workflowWait = false
    var missingLabels = false
    var oversizedRuns = false
    var oversizedJobs = false

    func fail() { failing = true }
    func usePagination() { paginate = true }
    func useWorkflowWait() { workflowWait = true }
    func useMissingLabels() { workflowWait = false; missingLabels = true }
    func useOversizedRuns() { oversizedRuns = true }
    func useOversizedJobs() { oversizedJobs = true }

    func get(_ path: String) throws -> Data {
        calls.append(path)
        if failing { throw GitHubBuildError.message("Fixture rate limit") }
        if path.contains("/runners?") {
            let runner = #"{"id":2,"name":"test-mac","status":"online","busy":true,"labels":[{"name":"self-hosted"},{"name":"macOS"},{"name":"ARM64"},{"name":"signing"}]}"#
            if paginate && path.contains("page=1") {
                let runners = Array(repeating: runner, count: 100).joined(separator: ",")
                return Data("{\"total_count\":101,\"runners\":[\(runners)]}".utf8)
            }
            return Data("{\"total_count\":\(paginate ? 101 : 1),\"runners\":[\(runner)]}".utf8)
        }
        if path.contains("/runs?status=in_progress") {
            if oversizedRuns {
                let ids = path.contains("page=2") ? Array(101...101) : Array(1...100)
                let runs = ids.map { id in
                    """
                    {"id":\(id),"name":"Build","display_title":"Build","run_number":\(id),"run_attempt":1,
                    "head_branch":"main","head_sha":"abcdef","status":"in_progress",
                    "created_at":"2026-09-08T09:00:00Z","html_url":"https://github.com/example/app/actions/runs/\(id)"}
                    """
                }.joined(separator: ",")
                return Data("{\"total_count\":101,\"workflow_runs\":[\(runs)]}".utf8)
            }
            return Data("""
            {"total_count":1,"workflow_runs":[{"id":50,"name":"TestFlight","display_title":"Build the app",
            "run_number":7,"run_attempt":2,"head_branch":"main","head_sha":"abcdef123",
            "status":"in_progress","created_at":"2026-09-08T09:00:00Z",
            "html_url":"https://github.com/example/app/actions/runs/50"}]}
            """.utf8)
        }
        if path.contains("/runs?") {
            return Data(#"{"total_count":0,"workflow_runs":[]}"#.utf8)
        }
        precondition(path.contains("/runs/50/attempts/2/jobs?"), "Use the current run attempt")
        if oversizedJobs {
            let page = Int(path.components(separatedBy: "&page=").last!)!
            let ids = page == 6 ? [501] : Array(((page - 1) * 100 + 1)...(page * 100))
            let jobs = ids.map { id in
                """
                {"id":\(id),"name":"Build","status":"queued","runner_id":0,"labels":["self-hosted"],
                "html_url":"https://github.com/example/app/actions/runs/50/job/\(id)"}
                """
            }.joined(separator: ",")
            return Data("{\"total_count\":501,\"jobs\":[\(jobs)]}".utf8)
        }
        if workflowWait { return Data(#"{"total_count":0,"jobs":[]}"#.utf8) }
        if missingLabels {
            return Data("""
            {"total_count":1,"jobs":[{"id":8,"name":"Approval","status":"waiting","runner_id":0,"labels":[],
            "html_url":"https://github.com/example/app/actions/runs/50/job/8","steps":[]}]}
            """.utf8)
        }
        return Data("""
        {"total_count":5,"jobs":[
        {"id":1,"name":"Upload","status":"in_progress","runner_id":2,"labels":["self-hosted"],
        "started_at":"2026-09-08T09:01:00Z","html_url":"https://github.com/example/app/actions/runs/50/job/1",
        "steps":[{"name":"Archive","status":"completed"},{"name":"Upload to TestFlight","status":"in_progress"}]},
        {"id":2,"name":"Next build","status":"queued","runner_id":0,"labels":["macOS","signing"],
        "started_at":null,"html_url":"https://github.com/example/app/actions/runs/50/job/2","steps":[]},
        {"id":3,"name":"Other machine","status":"in_progress","runner_id":99,"labels":["self-hosted"],
        "started_at":null,"html_url":"https://github.com/example/app/actions/runs/50/job/3","steps":[]},
        {"id":4,"name":"Hosted lint","status":"queued","runner_id":null,"labels":["ubuntu-latest"],
        "started_at":null,"html_url":"https://github.com/example/app/actions/runs/50/job/4","steps":[]},
        {"id":5,"name":"Finished","status":"completed","runner_id":2,"labels":["self-hosted"],
        "started_at":null,"html_url":"https://github.com/example/app/actions/runs/50/job/5","steps":[]}
        ]}
        """.utf8)
    }
}

@main
struct GitHubBuildTests {
    static func main() async throws {
        let target = GitHubBuildTarget(repository: "example/app", app: "App", runner: "test-mac")
        let fixture = Fixture()
        let api = GitHubActionsAPI { try await fixture.get($0) }
        let result = try await api.collect(target)
        precondition(result.jobs.count == 2, "Exclude completed, hosted and other-runner jobs")
        precondition(result.jobs[0].assignment == "assigned")
        precondition(result.jobs[0].step == "Upload to TestFlight")
        precondition(result.jobs[0].attempt == 2 && result.jobs[0].number == 7)
        precondition(result.jobs[1].assignment == "eligible")
        precondition(result.checkedAt != nil && result.runnerStatus == "online" && result.busy)
        let calls = await fixture.calls
        for status in ["queued", "in_progress", "waiting", "pending", "requested"] {
            precondition(calls.contains { $0.contains("status=\(status)&") })
        }

        await fixture.usePagination()
        _ = try await api.collect(target)
        let paginatedCalls = await fixture.calls
        precondition(paginatedCalls.contains { $0.contains("/runners?per_page=100&page=2") })
        await fixture.useWorkflowWait()
        let waiting = try await api.collect(target)
        precondition(waiting.jobs.count == 1 && waiting.jobs[0].assignment == "workflow",
                     "Unscheduled workflows must not be presented as assigned jobs")
        await fixture.useMissingLabels()
        let unknown = try await api.collect(target)
        precondition(unknown.jobs.count == 1 && unknown.jobs[0].assignment == "workflow",
                     "Jobs without eligibility data must not disappear or look assigned")
        let largeRuns = Fixture()
        await largeRuns.useOversizedRuns()
        do {
            _ = try await GitHubActionsAPI { try await largeRuns.get($0) }.collect(target)
            preconditionFailure("Oversized run lists must not appear complete")
        } catch GitHubBuildError.message(let message) { precondition(message.contains("100 active workflows")) }
        let largeJobs = Fixture()
        await largeJobs.useOversizedJobs()
        do {
            _ = try await GitHubActionsAPI { try await largeJobs.get($0) }.collect(target)
            preconditionFailure("Oversized job lists must not appear complete")
        } catch GitHubBuildError.message(let message) { precondition(message.contains("500 active jobs")) }

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cantrip-builds-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try JSONEncoder().encode([target]).write(to: file)
        let loaded = try GitHubBuildTarget.load(from: file)
        precondition(loaded == [target])
        let cacheFixture = Fixture()
        let monitor = GitHubBuildMonitor(configurationURL: file, refreshInterval: 0.1) {
            GitHubActionsAPI { try await cacheFixture.get($0) }
        }
        let initial = await monitor.snapshot()
        precondition(initial.isRefreshing && initial.repositories.isEmpty, "Snapshot must not wait for GitHub")
        let first = try await waitForSnapshot(monitor)
        precondition(first.repositories.first?.jobs.count == 2)
        let requestCount = await cacheFixture.calls.count
        _ = await monitor.snapshot()
        let cachedCount = await cacheFixture.calls.count
        precondition(requestCount == cachedCount, "Coalesce reads and honor refresh interval")
        await cacheFixture.fail()
        try await Task.sleep(for: .milliseconds(110))
        _ = await monitor.snapshot()
        let failed = try await waitForSnapshot(monitor)
        precondition(failed.repositories.first?.warning == "Fixture rate limit")
        precondition(failed.repositories.first?.jobs.count == 2, "Failure retains explicitly stale data")
        precondition(failed.repositories.first?.checkedAt == first.repositories.first?.checkedAt)
        let encoded = String(decoding: try JSONEncoder().encode(failed), as: UTF8.self)
        precondition(!encoded.contains("token") && !encoded.contains("Authorization"))

        for repository in ["https://evil.example/a", "example/app?x=y", "../app", "example/app/extra", "example/.."] {
            let invalid = GitHubBuildTarget(repository: repository, app: "App", runner: "test-mac")
            try JSONEncoder().encode([invalid]).write(to: file)
            do {
                _ = try GitHubBuildTarget.load(from: file)
                preconditionFailure("Reject unsafe repository paths")
            } catch GitHubBuildError.message {}
        }
        try JSONEncoder().encode([target, target]).write(to: file)
        do {
            _ = try GitHubBuildTarget.load(from: file)
            preconditionFailure("Reject duplicate repositories")
        } catch GitHubBuildError.message {}
        print("GitHub build matching, stages, attempts, pagination, cache, stale errors and configuration passed")

        if ProcessInfo.processInfo.environment["CANTRIP_BUILDS_LIVE_TEST"] == "1" {
            let live = try await GitHubActionsAPI.authenticated()
            let targets = try GitHubBuildTarget.load(from: GitHubBuildMonitor.configurationURL)
            for target in targets {
                let value = try await live.collect(target)
                print("\(value.app): \(value.runner) \(value.runnerStatus), busy=\(value.busy), \(value.jobs.count) active/waiting entries")
                for job in value.jobs {
                    print("  \(job.workflow) #\(job.number): \(job.job) - \(job.status) - \(job.assignment) - \(job.step ?? "no active step")")
                }
            }
        }
    }

    static func waitForSnapshot(_ monitor: GitHubBuildMonitor) async throws -> GitHubBuildSnapshot {
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(5))
            let value = await monitor.snapshot()
            if !value.isRefreshing { return value }
        }
        fatalError("Snapshot never finished")
    }
}
