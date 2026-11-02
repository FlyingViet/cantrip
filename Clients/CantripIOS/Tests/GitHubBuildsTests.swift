import SwiftUI
import XCTest
@testable import Hermes

private final class BuildRequestProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (status, data) = try handler(request)
            let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url),
                statusCode: status, httpVersion: nil, headerFields: nil))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}

final class GitHubBuildsTests: XCTestCase {
    override func tearDown() {
        BuildRequestProtocol.handler = nil
        super.tearDown()
    }

    private func api() throws -> CantripRemoteAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BuildRequestProtocol.self]
        return CantripRemoteAPI(
            transport: .remote(try XCTUnwrap(URL(string: "https://cantrip.example"))),
            token: "build-test-token", urlSession: URLSession(configuration: configuration))
    }

    private func fixture(checkedAt: String? = nil, warning: String? = nil, url: String? = nil) throws -> Data {
        var repository: [String: Any] = [
            "repository": "example/app", "app": "An app with a long descriptive name",
            "runner": "build-mac", "runnerStatus": "online", "busy": true,
            "checkedAt": checkedAt ?? ISO8601DateFormatter().string(from: Date()),
            "jobs": [
                job(id: "running", status: "in_progress", assignment: "assigned",
                    createdAt: "2026-09-08T09:01:00Z", url: url),
                job(id: "queued", status: "queued", assignment: "eligible",
                    createdAt: "2026-09-08T09:00:00Z"),
                job(id: "waiting", status: "waiting", assignment: "workflow",
                    createdAt: "2026-09-08T09:02:00Z"),
            ],
        ]
        if let warning { repository["warning"] = warning }
        return try JSONSerialization.data(withJSONObject: [
            "repositories": [repository], "isRefreshing": false,
        ])
    }

    private func job(id: String, status: String, assignment: String,
                     createdAt: String, url: String? = nil) -> [String: Any] {
        [
            "id": id, "workflow": "iOS TestFlight", "title": "Ship a new app feature",
            "number": 49, "attempt": 2, "branch": "feature/a-long-branch-name",
            "commit": "abc123456789", "status": status, "job": "Build and upload",
            "step": "Export and upload to TestFlight", "createdAt": createdAt,
            "startedAt": "2026-09-08T09:02:00Z",
            "url": url ?? "https://github.com/example/app/actions/runs/50/job/1",
            "assignment": assignment,
        ]
    }

    private func repository(_ name: String, jobs: [[String: Any]], busy: Bool = false,
                            runnerStatus: String = "online", checkedAt: String? = nil,
                            warning: String? = nil) throws -> CantripBuildRepository {
        var value: [String: Any] = [
            "repository": "example/\(name)", "app": name, "runner": "\(name)-mac",
            "runnerStatus": runnerStatus, "busy": busy, "jobs": jobs,
            "checkedAt": checkedAt ?? ISO8601DateFormatter().string(from: Date()),
        ]
        if let warning { value["warning"] = warning }
        return try JSONDecoder().decode(CantripBuildRepository.self,
                                        from: JSONSerialization.data(withJSONObject: value))
    }

    private func aggregateFixture() throws -> CantripBuildSnapshot {
        CantripBuildSnapshot(repositories: [
            try repository("Busy app", jobs: [
                job(id: "running", status: "in_progress", assignment: "assigned",
                    createdAt: "2026-09-08T08:00:00Z"),
                job(id: "busy-queue", status: "queued", assignment: "eligible",
                    createdAt: "2026-09-08T09:00:00Z"),
            ], busy: true),
            try repository("Waiting app", jobs: [
                job(id: "workflow-wait", status: "pending", assignment: "workflow",
                    createdAt: "2026-09-08T07:00:00Z"),
            ]),
            try repository("Ready app", jobs: [
                job(id: "ready-queue", status: "queued", assignment: "eligible",
                    createdAt: "2026-09-08T10:00:00Z"),
            ]),
        ], isRefreshing: false)
    }

    func testAggregateQueueIncludesAllAppsAndWorkflowWaitsInEstimatedOrder() throws {
        let snapshot = try aggregateFixture()
        let queue = snapshot.buildQueue()
        XCTAssertEqual(queue.map(\.id), ["ready-queue", "busy-queue", "workflow-wait"])
        XCTAssertEqual(queue.map(\.position), [1, 2, 3])
        XCTAssertEqual(queue.filter(\.isUpNext).map(\.id), ["ready-queue"])
        XCTAssertEqual(queue.map(\.entry.repository.app), ["Ready app", "Busy app", "Waiting app"])
        XCTAssertEqual(queue.map(\.entry.queueReadiness), [.ready, .runnerBusy, .blocked])
        XCTAssertTrue(queue[0].entry.queueReason.contains("Runner available"))
        XCTAssertTrue(queue[1].entry.queueReason.contains("finish its current work"))
        XCTAssertTrue(queue[2].entry.queueReason.contains("eligibility is not yet known"))
        XCTAssertEqual(snapshot.entries.filter { $0.job.isRunning }.map(\.id), ["running"])
    }

    func testQueueIsOldestFirstAcrossRepositoriesWithStableTies() throws {
        let old = job(id: "old", status: "queued", assignment: "eligible",
                      createdAt: "2026-09-08T07:00:00Z")
        let newerA = job(id: "new-a", status: "queued", assignment: "eligible",
                         createdAt: "2026-09-08T10:00:00Z")
        let newerB = job(id: "new-b", status: "queued", assignment: "assigned",
                         createdAt: "2026-09-08T10:00:00Z")
        let first = try repository("First", jobs: [newerB, old])
        let second = try repository("Second", jobs: [newerA])
        for repositories in [[first, second], [second, first]] {
            let queue = CantripBuildSnapshot(repositories: repositories, isRefreshing: false).buildQueue()
            XCTAssertEqual(queue.map(\.id), ["old", "new-a", "new-b"])
            XCTAssertEqual(queue.filter(\.isUpNext).map(\.id), ["old"])
        }
    }

    func testBlockedAndOfflineEntriesRemainVisibleButNeverBecomeUpNext() throws {
        let snapshot = CantripBuildSnapshot(repositories: [
            try repository("Offline", jobs: [
                job(id: "offline", status: "queued", assignment: "eligible",
                    createdAt: "2026-09-08T07:00:00Z"),
            ], runnerStatus: "offline"),
            try repository("Held", jobs: [
                job(id: "approval", status: "waiting", assignment: "eligible",
                    createdAt: "2026-09-08T08:00:00Z"),
                job(id: "concurrency", status: "pending", assignment: "assigned",
                    createdAt: "2026-09-08T09:00:00Z"),
                job(id: "unknown-workflow", status: "queued", assignment: "workflow",
                    createdAt: "2026-09-08T10:00:00Z"),
                job(id: "completed", status: "completed", assignment: "assigned",
                    createdAt: "2026-09-08T06:00:00Z"),
            ]),
        ], isRefreshing: false)
        let queue = snapshot.buildQueue()
        XCTAssertEqual(queue.map(\.id), ["offline", "approval", "concurrency", "unknown-workflow"])
        XCTAssertFalse(queue.contains(where: \.isUpNext))
        XCTAssertTrue(queue.allSatisfy { $0.entry.queueReadiness == .blocked })
        XCTAssertTrue(queue[0].entry.queueReason.contains("offline"))
        XCTAssertTrue(queue[1].entry.queueReason.contains("Waiting on GitHub"))
    }

    func testBusyRunnerCanBeNextAfterCurrentBuildButNotReadyNow() throws {
        // A running job is authoritative even if the runner's busy flag lags.
        let repository = try repository("Busy", jobs: [
            job(id: "running", status: "in_progress", assignment: "assigned",
                createdAt: "2026-09-08T08:00:00Z"),
            job(id: "next", status: "in_progress", assignment: "eligible",
                createdAt: "2026-09-08T09:00:00Z"),
        ])
        let queue = CantripBuildSnapshot(repositories: [repository], isRefreshing: false).buildQueue()
        XCTAssertEqual(queue.map(\.id), ["next"])
        XCTAssertEqual(queue.first?.entry.queueReadiness, .runnerBusy)
        XCTAssertEqual(queue.first?.isUpNext, true)
    }

    func testStalePartialAndFailedSnapshotsSuppressUpNextWithoutLosingQueue() throws {
        var snapshot = try aggregateFixture()
        XCTAssertFalse(snapshot.buildQueue(canEstimate: false).contains(where: \.isUpNext))
        snapshot.error = "GitHub unavailable"
        XCTAssertEqual(snapshot.buildQueue().count, 3)
        XCTAssertFalse(snapshot.buildQueue().contains(where: \.isUpNext))
        snapshot.error = nil
        for staleRepository in [
            try repository("Stale", jobs: [
                job(id: "stale", status: "queued", assignment: "eligible",
                    createdAt: "2026-09-08T06:00:00Z"),
            ], checkedAt: "2020-01-01T00:00:00Z"),
            try repository("Stale", jobs: [
                job(id: "stale", status: "queued", assignment: "eligible",
                    createdAt: "2026-09-08T06:00:00Z"),
            ], warning: "GitHub denied access"),
        ] {
            let partial = CantripBuildSnapshot(repositories: snapshot.repositories + [staleRepository],
                                              isRefreshing: false)
            let queue = partial.buildQueue()
            XCTAssertEqual(queue.map(\.id), ["ready-queue", "busy-queue", "workflow-wait", "stale"])
            XCTAssertEqual(queue.last?.entry.queueReadiness, .unknown)
            XCTAssertFalse(queue.contains(where: \.isUpNext))
        }
        XCTAssertTrue(CantripBuildSnapshot(repositories: [], isRefreshing: false).buildQueue().isEmpty)
    }

    func testAuthenticatedReadOnlySnapshotUsesExistingDeadline() async throws {
        let data = try fixture()
        var calls = 0
        BuildRequestProtocol.handler = { request in
            calls += 1
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/v1/github/builds")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer build-test-token")
            XCTAssertEqual(request.timeoutInterval, 3)
            XCTAssertNil(request.httpBody)
            return (200, data)
        }
        let snapshot = try await api().githubBuilds()
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(snapshot.isComplete)
        XCTAssertEqual(snapshot.entries.map(\.id), ["queued", "running", "waiting"])
        XCTAssertEqual(snapshot.entries.filter { $0.job.isRunning }.map(\.id), ["running"])
        XCTAssertEqual(snapshot.entries.filter { $0.job.isWorkflowWait }.map(\.id), ["waiting"])
        XCTAssertEqual(snapshot.entries[1].job.step, "Export and upload to TestFlight")
    }

    func testOldHostsAndAuthenticationAreNotEmptyQueues() async throws {
        BuildRequestProtocol.handler = { _ in (404, Data(#"{"error":"not found"}"#.utf8)) }
        do {
            _ = try await api().githubBuilds()
            XCTFail("Old hosts need an update notice")
        } catch CantripRemoteError.githubBuildsUnsupported {}
        BuildRequestProtocol.handler = { _ in (401, Data(#"{"error":"unauthorized"}"#.utf8)) }
        do {
            _ = try await api().githubBuilds()
            XCTFail("Bad pairing tokens must surface")
        } catch CantripRemoteError.authentication {}
        BuildRequestProtocol.handler = { _ in (200, Data(#"{"repositories":[]}"#.utf8)) }
        do {
            _ = try await api().githubBuilds()
            XCTFail("Malformed responses must surface")
        } catch CantripRemoteError.decoding {}
    }

    @MainActor
    func testFailuresRetainSnapshotAndCancellationDoesNotOverwrite() async throws {
        let snapshot = try JSONDecoder().decode(CantripBuildSnapshot.self, from: fixture())
        let model = GitHubBuildsModel()
        await model.refresh { snapshot }
        await model.refresh { throw CantripRemoteError.transport("Offline") }
        XCTAssertEqual(model.snapshot?.entries.count, 3)
        XCTAssertTrue(model.error?.contains("Offline") == true)
        await model.refresh { throw CancellationError() }
        XCTAssertTrue(model.error?.contains("Offline") == true)
        XCTAssertFalse(model.isLoading)
        await model.refresh { snapshot }
        XCTAssertNil(model.error)
    }

    func testFreshnessAndPartialErrorsPreventFalseIdleState() throws {
        let decoder = JSONDecoder()
        let stale = try decoder.decode(CantripBuildSnapshot.self, from: fixture(checkedAt: "2020-01-01T00:00:00Z"))
        XCTAssertFalse(stale.isComplete)
        let partial = try decoder.decode(CantripBuildSnapshot.self, from: fixture(warning: "GitHub access denied"))
        XCTAssertFalse(partial.isComplete)
        XCTAssertEqual(partial.entries.count, 3)
        XCTAssertFalse(CantripBuildSnapshot(repositories: [], isRefreshing: false).isComplete)
    }

    func testLinksOnlyOpenExpectedGitHubBuilds() throws {
        for url in ["https://evil.example/example/app/actions/runs/50",
                    "http://github.com/example/app/actions/runs/50",
                    "https://github.com/other/repo/actions/runs/50",
                    "https://user@github.com/example/app/actions/runs/50"] {
            let value = try JSONDecoder().decode(CantripBuildSnapshot.self, from: fixture(url: url))
            XCTAssertNil(value.entries.first { $0.id == "running" }?.githubURL)
        }
        let value = try JSONDecoder().decode(CantripBuildSnapshot.self, from: fixture())
        XCTAssertNotNil(value.entries.first?.githubURL)
    }

    @MainActor
    func testBuildRowsFitNarrowAndAccessibilityLayouts() throws {
        let snapshot = try JSONDecoder().decode(CantripBuildSnapshot.self, from: fixture())
        let rows = snapshot.entries.map { GitHubBuildRow(entry: $0) }
            + (try aggregateFixture()).buildQueue().map {
                GitHubBuildRow(entry: $0.entry, queuePosition: $0.position, isUpNext: $0.isUpNext)
            }
        for row in rows {
            for width: CGFloat in [288, 720] {
                for size in [DynamicTypeSize.large, .accessibility3, .accessibility5] {
                    let host = UIHostingController(rootView: row
                        .environment(\.dynamicTypeSize, size))
                    let measured = host.sizeThatFits(in: CGSize(width: width, height: 5_000))
                    XCTAssertLessThanOrEqual(measured.width, width + 1)
                    XCTAssertGreaterThan(measured.height, 100)
                    XCTAssertLessThan(measured.height, 2_500)
                }
            }
        }

    }

    @MainActor
    func testAggregateQueueRendersInListAtNarrowAndAccessibilitySizes() throws {
        let snapshot = try aggregateFixture()
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        for size: DynamicTypeSize in [.large, .accessibility3] {
            let controller = UIHostingController(rootView: NavigationStack {
                List {
                    GitHubBuildQueueSection(snapshot: snapshot)
                }
                .navigationTitle("GitHub Builds")
                .navigationBarTitleDisplayMode(.inline)
            }.environment(\.dynamicTypeSize, size))
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 320, height: 900)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            controller.view.layoutIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "aggregate-build-queue-\(size)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
}
