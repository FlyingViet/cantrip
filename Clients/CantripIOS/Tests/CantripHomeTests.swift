import Combine
import SwiftUI
import UIKit
import XCTest
@testable import Hermes

private final class CantripHomeRequestProtocol: URLProtocol {
    @MainActor static var handler: ((URLRequest) async throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Task { @MainActor in
            do {
                let handler = try XCTUnwrap(Self.handler)
                let (status, data) = try await handler(request)
                let response = try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url), statusCode: status,
                    httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
                ))
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }
}

@MainActor
final class CantripHomeTests: XCTestCase {
    private let homeID = "7EAE0CE5-8C8B-4652-9FD0-214867A90E5D"

    private func client() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CantripHomeRequestProtocol.self]
        return URLSession(configuration: configuration)
    }

    func testHomeLaneUsesFocusedRemotePresentation() {
        XCTAssertEqual(ExecutionLane.home.title, "Cantrip Home")
        XCTAssertEqual(ExecutionLane.home.systemImage, "house.fill")
        XCTAssertTrue(ExecutionLane.home.usesCantripRemote)
        XCTAssertFalse(ExecutionLane.home.isPrivate)
        XCTAssertEqual(CantripHomeSection.allCases, [.chat, .tasks, .artifacts])
    }

    func testHomeViewModelUsesPermanentLockedRemoteConversation() {
        let env = HermesEnv()
        let original = env.executionLane
        defer { env.select(original) }
        env.select(.home)
        let vm = ChatViewModel(
            env: env, remote: CantripRemoteModel(), voice: VoiceController()
        )
        XCTAssertEqual(vm.activeLane, .home)
        XCTAssertEqual(vm.tabTitle, "Cantrip Home")
        XCTAssertTrue(vm.isTabLocked)
    }

    func testHomeAPIReadsSessionTasksArtifactsAndMutatesTask() async throws {
        let client = client()
        let api = CantripRemoteAPI(
            transport: .remote(try XCTUnwrap(URL(string: "https://cantrip.example"))),
            token: "home-token", urlSession: client
        )
        var requests: [(String, String)] = []
        CantripHomeRequestProtocol.handler = { request in
            let path = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
            requests.append((request.httpMethod ?? "", path))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer home-token")
            switch (request.httpMethod, path) {
            case ("GET", "/api/v1/home"):
                return (200, self.homeSessionPayload())
            case ("GET", "/api/v1/home/tasks"):
                return (200, self.tasksPayload(enabled: true))
            case ("GET", "/api/v1/home/artifacts"):
                return (200, self.artifactsPayload())
            case ("POST", let value) where value.hasSuffix("/records"):
                return (200, self.workspaceTaskPayload())
            case ("PATCH", let value) where value.contains("/records/"):
                return (200, self.workspaceTaskPayload(status: "Interview"))
            case ("DELETE", let value) where value.contains("/records/"):
                return (200, self.workspaceTaskPayload())
            case ("PATCH", let value) where value.hasPrefix("/api/v1/home/tasks/"):
                return (200, self.taskPayload(enabled: false))
            case ("DELETE", let value) where value.hasPrefix("/api/v1/home/tasks/"):
                return (200, Data(#"{"deleted":true}"#.utf8))
            case ("GET", let value) where value.hasPrefix("/api/v1/home/artifacts/"):
                return (200, Data(#"{"artifact":{"id":"20000000-0000-0000-0000-000000000001","title":"Flight report","mimeType":"text/markdown"},"data":"UmVwb3J0"}"#.utf8))
            default:
                XCTFail("Unexpected Home request: \(request.httpMethod ?? "") \(path)")
                return (404, Data(#"{"error":"unexpected"}"#.utf8))
            }
        }
        addTeardownBlock { @MainActor in
            client.invalidateAndCancel()
            CantripHomeRequestProtocol.handler = nil
        }

        let session = try await api.homeSession()
        XCTAssertEqual(session.id, homeID)
        XCTAssertEqual(session.isCantripHome, true)
        let tasks = try await api.homeTasks()
        XCTAssertEqual(tasks.tasks.first?.title, "Track SFO flights")
        XCTAssertEqual(tasks.tasks.first?.schedule.kind, .weekdays)
        let tracker = try XCTUnwrap(tasks.tasks.first { $0.workspace != nil })
        XCTAssertFalse(tracker.isScheduled)
        XCTAssertEqual(tracker.workspace?.list.badgeField, "status")
        XCTAssertEqual(tracker.workspace?.records.first?.values["company"], "Example Co")
        let artifacts = try await api.homeArtifacts()
        XCTAssertEqual(artifacts.artifacts.first?.kind, "document")
        let task = try XCTUnwrap(tasks.tasks.first)
        let paused = try await api.updateHomeTask(id: task.id, enabled: false)
        XCTAssertFalse(paused.enabled)
        try await api.deleteHomeTask(id: task.id)
        let created = try await api.createHomeTaskRecord(
            taskID: tracker.id,
            values: ["company": "Second Co", "appliedAt": "2026-09-30", "status": "Applied"]
        )
        let record = try XCTUnwrap(created.workspace?.records.first)
        let advanced = try await api.updateHomeTaskRecord(
            taskID: tracker.id, recordID: record.id, values: ["status": "Interview"]
        )
        XCTAssertEqual(advanced.workspace?.records.first?.values["status"], "Interview")
        _ = try await api.deleteHomeTaskRecord(taskID: tracker.id, recordID: record.id)
        let data = try await api.homeArtifactData(id: try XCTUnwrap(artifacts.artifacts.first?.id))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "Report")
        XCTAssertTrue(requests.contains { $0.0 == "GET" && $0.1 == "/api/v1/home" })
    }

    func testUnchangedHomeRefreshDoesNotRepublishSnapshots() async throws {
        let client = client()
        let model = CantripRemoteModel(urlSession: client)
        let unchangedTasks = tasksPayload(enabled: true)
        let unchangedArtifacts = artifactsPayload()
        CantripHomeRequestProtocol.handler = { request in
            let path = URLComponents(
                url: request.url!, resolvingAgainstBaseURL: false
            )?.percentEncodedPath ?? ""
            switch path {
            case "/api/v1/home": return (200, self.homeSessionPayload())
            case "/api/v1/home/tasks": return (200, unchangedTasks)
            case "/api/v1/home/artifacts": return (200, unchangedArtifacts)
            default: return (200, Data(#"{"sessions":[]}"#.utf8))
            }
        }
        addTeardownBlock { @MainActor in
            model.clearConfiguration()
            client.invalidateAndCancel()
            CantripHomeRequestProtocol.handler = nil
        }
        let configured = await model.configure(
            url: "https://cantrip.example",
            pairingToken: "home-refresh-token",
            tailscaleOnly: true
        )
        XCTAssertTrue(configured)
        await model.selectHome()
        XCTAssertEqual(model.homeTasks.count, 2)
        XCTAssertEqual(model.homeArtifacts.count, 1)

        var taskPublishes = 0
        var artifactPublishes = 0
        var loadingPublishes = 0
        var subscriptions: Set<AnyCancellable> = []
        model.$homeTasks.dropFirst().sink { _ in taskPublishes += 1 }.store(in: &subscriptions)
        model.$homeArtifacts.dropFirst().sink { _ in artifactPublishes += 1 }
            .store(in: &subscriptions)
        model.$isLoadingHomeData.dropFirst().sink { _ in loadingPublishes += 1 }
            .store(in: &subscriptions)

        await model.refreshHomeData()

        XCTAssertEqual(taskPublishes, 0)
        XCTAssertEqual(artifactPublishes, 0)
        XCTAssertEqual(loadingPublishes, 0)
    }

    func testHomeFocusedScreenshots() async throws {
        let directory = ProcessInfo.processInfo.environment["TEST_RUNNER_HOME_ARTIFACT_DIR"]
        guard let directory, !directory.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_HOME_ARTIFACT_DIR to render Cantrip Home.")
        }
        let client = client()
        let model = CantripRemoteModel(urlSession: client)
        CantripHomeRequestProtocol.handler = { request in
            let path = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
            switch path {
            case "/api/v1/home": return (200, self.homeSessionPayload())
            case "/api/v1/home/tasks": return (200, self.tasksPayload(enabled: true))
            case "/api/v1/home/artifacts": return (200, self.artifactsPayload())
            default: return (200, Data(#"{"sessions":[]}"#.utf8))
            }
        }
        addTeardownBlock { @MainActor in
            model.clearConfiguration()
            client.invalidateAndCancel()
            CantripHomeRequestProtocol.handler = nil
        }
        let configured = await model.configure(
            url: "https://cantrip.example", pairingToken: "home-token", tailscaleOnly: true
        )
        XCTAssertTrue(configured)
        await model.selectHome()
        XCTAssertTrue(model.isHomeSelected)
        XCTAssertEqual(model.homeTasks.count, 2)
        XCTAssertEqual(model.homeArtifacts.count, 1)

        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        for (name, style) in [("light", UIUserInterfaceStyle.light), ("dark", .dark)] {
            let controller = UIHostingController(rootView:
                VStack(spacing: 0) {
                    NavigationStack {
                        CantripHomeTasksView(remote: model, openChat: { _ in })
                    }
                    CantripHomeTabBar(selection: .constant(.tasks), runningTasks: 1)
                }
                .frame(width: 393)
                .background(Color(.systemBackground))
            )
            controller.overrideUserInterfaceStyle = style
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: CGSize(width: 393, height: 852))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            try await Task.sleep(for: .milliseconds(250))
            controller.view.frame = window.bounds
            controller.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try XCTUnwrap(image.pngData()).write(
                to: output.appendingPathComponent("cantrip-home-tasks-\(name).png")
            )

            let workspaceController = UIHostingController(rootView:
                NavigationStack {
                    CantripHomeTaskWorkspaceView(
                        remote: model,
                        taskID: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
                        openChat: { _ in }
                    )
                }
                .frame(width: 393)
                .background(Color(.systemBackground))
            )
            workspaceController.overrideUserInterfaceStyle = style
            window.rootViewController = workspaceController
            try await Task.sleep(for: .milliseconds(200))
            workspaceController.view.frame = window.bounds
            workspaceController.view.layoutIfNeeded()
            let workspaceImage = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try XCTUnwrap(workspaceImage.pngData()).write(
                to: output.appendingPathComponent("cantrip-home-workspace-\(name).png")
            )

            let artifactController = UIHostingController(rootView:
                VStack(spacing: 0) {
                    NavigationStack {
                        CantripHomeArtifactsView(remote: model, openChat: { _ in })
                    }
                    CantripHomeTabBar(selection: .constant(.artifacts), runningTasks: 0)
                }
                .frame(width: 393)
                .background(Color(.systemBackground))
            )
            artifactController.overrideUserInterfaceStyle = style
            window.rootViewController = artifactController
            try await Task.sleep(for: .milliseconds(200))
            artifactController.view.frame = window.bounds
            artifactController.view.layoutIfNeeded()
            let artifactImage = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try XCTUnwrap(artifactImage.pngData()).write(
                to: output.appendingPathComponent("cantrip-home-artifacts-\(name).png")
            )
        }
    }

    private func homeSessionPayload() -> Data {
        Data("""
        {"session":{"id":"\(homeID)","title":"Cantrip Home","workdir":"/tmp",
        "isStreaming":false,"canResume":false,"councilMode":false,"queuedCount":0,
        "status":null,"messages":[],"supportsImageAttachments":true,"queued":[],
        "supportsAutoDelivery":true,"isLocked":true,"isCantripHome":true,
        "supportsModelSettings":true,"supportsPagedHistory":true}}
        """.utf8)
    }

    private func tasksPayload(enabled: Bool) -> Data {
        Data("""
        {"tasks":[\(String(decoding: taskPayload(enabled: enabled), as: UTF8.self)),
        \(String(decoding: workspaceTaskPayload(), as: UTF8.self))],
        "revision":"task-revision"}
        """.utf8)
    }

    private func taskPayload(enabled: Bool) -> Data {
        let next = Date().addingTimeInterval(3_600).timeIntervalSinceReferenceDate
        return Data("""
        {"id":"10000000-0000-0000-0000-000000000001","title":"Track SFO flights",
        "prompt":"Check prices from SFO to JFK.","schedule":{"kind":"weekdays",
        "summary":"Weekdays at 8 AM","timeZone":"America/Los_Angeles","startAt":null,
        "intervalMinutes":null,"weekdays":[2,3,4,5,6],"hour":8,"minute":0},
        "enabled":\(enabled),"createdAt":0,"updatedAt":0,"nextRunAt":\(next),
        "lastRunAt":null,"state":"running","activeRunID":null,"runs":[]}
        """.utf8)
    }

    private func workspaceTaskPayload(status: String = "Applied") -> Data {
        let now = Date().timeIntervalSinceReferenceDate
        return Data("""
        {"id":"10000000-0000-0000-0000-000000000002","title":"Job applications",
        "prompt":"Track each job application lifecycle.","schedule":{"kind":"once",
        "summary":"No schedule","timeZone":"America/Los_Angeles","startAt":null,
        "intervalMinutes":null,"weekdays":null,"hour":null,"minute":null},
        "hasSchedule":false,"enabled":false,"createdAt":\(now),"updatedAt":\(now),
        "nextRunAt":null,"lastRunAt":null,"state":"ready","activeRunID":null,"runs":[],
        "workspace":{"recordLabel":"Application","recordLabelPlural":"Applications",
        "icon":"briefcase.fill","fields":[
        {"key":"company","label":"Company","kind":"text","required":true,"options":null},
        {"key":"appliedAt","label":"Applied","kind":"date","required":true,"options":null},
        {"key":"status","label":"Status","kind":"choice","required":true,
        "options":["Applied","Interview","Offer","Closed"]},
        {"key":"round","label":"Interview round","kind":"number","required":false,"options":null},
        {"key":"interviewAt","label":"Interview","kind":"dateTime","required":false,"options":null}],
        "list":{"titleField":"company","subtitleFields":["round"],"badgeField":"status",
        "dateField":"appliedAt"},"detailSections":[{"title":"Lifecycle",
        "fields":["appliedAt","status","round","interviewAt"]}],"records":[
        {"id":"30000000-0000-0000-0000-000000000001",
        "values":{"company":"Example Co","appliedAt":"2026-09-29","status":"\(status)",
        "round":"2","interviewAt":"2026-10-03T17:00:00Z"},
        "createdAt":\(now),"updatedAt":\(now)}]}}
        """.utf8)
    }

    private func artifactsPayload() -> Data {
        Data("""
        {"artifacts":[{"id":"20000000-0000-0000-0000-000000000001",
        "title":"Flight report","relativePath":"flight-report.md","kind":"document",
        "mimeType":"text/markdown","size":128,"createdAt":0}],"revision":"artifact-revision"}
        """.utf8)
    }
}
