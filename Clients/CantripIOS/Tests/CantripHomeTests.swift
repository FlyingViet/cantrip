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

    func testHomeBadgeTonesUseHiringLifecycleSemantics() {
        XCTAssertEqual(CantripHomeBadgeTone(value: "Rejected"), .rejected)
        XCTAssertEqual(CantripHomeBadgeTone(value: "Application declined"), .rejected)
        XCTAssertEqual(CantripHomeBadgeTone(value: "Offer"), .offer)
        XCTAssertEqual(CantripHomeBadgeTone(value: "Applied"), .applied)
        XCTAssertEqual(CantripHomeBadgeTone(value: "Application received"), .applied)
        XCTAssertEqual(
            CantripHomeBadgeTone(value: "Recruiter conversation scheduled"),
            .inProgress
        )
        XCTAssertEqual(CantripHomeBadgeTone(value: "Healthy"), .accent)
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

    func testHomeEmptyChatDistinguishesReadyOpeningAndUnavailable() {
        XCTAssertEqual(
            CantripHomeChatAvailability.resolve(
                isConfigured: true,
                isHomeSelected: true,
                isHomeSession: true,
                error: nil
            ),
            .ready
        )
        XCTAssertEqual(
            CantripHomeChatAvailability.resolve(
                isConfigured: true,
                isHomeSelected: true,
                isHomeSession: false,
                error: nil
            ),
            .opening
        )
        XCTAssertEqual(
            CantripHomeChatAvailability.resolve(
                isConfigured: true,
                isHomeSelected: true,
                isHomeSession: false,
                error: "Home is disabled on the Mac."
            ),
            .unavailable("Home is disabled on the Mac.")
        )
    }

    func testPollingRetriesDefaultHomeAfterColdLaunchRouteFailure() async throws {
        let client = client()
        let model = CantripRemoteModel(urlSession: client)
        var failFirstHomeRequest = true
        CantripHomeRequestProtocol.handler = { request in
            let path = URLComponents(
                url: request.url!,
                resolvingAgainstBaseURL: false
            )?.percentEncodedPath ?? ""
            if path == "/api/v1/home", failFirstHomeRequest {
                failFirstHomeRequest = false
                throw URLError(.notConnectedToInternet)
            }
            switch path {
            case "/api/v1/home":
                return (200, self.homeSessionPayload())
            case "/api/v1/home/tasks":
                return (200, self.tasksPayload(enabled: true))
            case "/api/v1/home/artifacts":
                return (200, self.artifactsPayload())
            default:
                return (200, Data(#"{"sessions":[]}"#.utf8))
            }
        }
        addTeardownBlock { @MainActor in
            model.setAppActive(false)
            model.clearConfiguration()
            client.invalidateAndCancel()
            CantripHomeRequestProtocol.handler = nil
        }
        let configured = await model.configure(
            url: "https://cantrip.example",
            pairingToken: "cold-home-token",
            tailscaleOnly: true
        )
        XCTAssertTrue(configured)

        await model.selectHome()
        XCTAssertTrue(model.isHomeSelected)
        XCTAssertNil(model.selectedSessionID)
        XCTAssertNotNil(model.detailError)

        model.setAppActive(true)
        let deadline = ContinuousClock.now + .seconds(3)
        while model.selectedSession?.isCantripHome != true,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(model.selectedSessionID, homeID)
        XCTAssertEqual(model.selectedSession?.isCantripHome, true)
        XCTAssertNil(model.detailError)
        XCTAssertFalse(model.homeTasks.isEmpty)
    }

    func testHomeUsesCompactBottomBarOnIPhone() async throws {
        let controller = UIHostingController(rootView:
            CantripHomeTabs(selection: .constant(.tasks), runningTasks: 2) {
                Text("Chat")
            } tasks: {
                Text("Tasks")
            } artifacts: {
                Text("Artifacts")
            }
        )
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: CGSize(width: 393, height: 852))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(200))
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()

        let tabBar: UITabBar = try XCTUnwrap(firstSubview(in: controller.view))
        XCTAssertEqual(tabBar.items?.compactMap(\.title), ["Chat", "Tasks", "Artifacts"])
        XCTAssertEqual(tabBar.selectedItem?.title, "Tasks")
        XCTAssertEqual(tabBar.selectedItem?.badgeValue, "2")
        let tabBarFrame = tabBar.convert(tabBar.bounds, to: window)
        XCTAssertTrue(
            tabBar.isHidden || tabBar.alpha == 0 || tabBarFrame.minY >= window.bounds.maxY,
            "System tab bar remains visible: hidden=\(tabBar.isHidden), "
                + "alpha=\(tabBar.alpha), frame=\(tabBarFrame)"
        )
        let tabController: UITabBarController = try XCTUnwrap(firstViewController(in: controller))
        XCTAssertEqual(tabController.tabBarMinimizeBehavior, .never)

        let compactBar = CantripHomeCompactTabBar(
            selection: .constant(.tasks),
            runningTasks: 2
        )
        let compactController = UIHostingController(rootView: compactBar)
        XCTAssertEqual(
            compactController.sizeThatFits(in: CGSize(width: 369, height: 100)).height,
            48,
            accuracy: 1
        )
        let accessibilityController = UIHostingController(
            rootView: compactBar.environment(\.dynamicTypeSize, .accessibility5)
        )
        XCTAssertEqual(
            accessibilityController.sizeThatFits(in: CGSize(width: 296, height: 100)).height,
            48,
            accuracy: 1
        )
    }

    func testEveryHomeTabClearsCompactBottomBar() async throws {
        for section in CantripHomeSection.allCases {
            for size: DynamicTypeSize in [.large, .accessibility5] {
                var chatFrame = CGRect.zero
                var tasksFrame = CGRect.zero
                var artifactsFrame = CGRect.zero
                let controller = UIHostingController(rootView:
                    CantripHomeTabs(selection: .constant(section), runningTasks: 0) {
                        bottomContentProbe(frame: { chatFrame = $0 })
                    } tasks: {
                        bottomContentProbe(frame: { tasksFrame = $0 })
                    } artifacts: {
                        bottomContentProbe(frame: { artifactsFrame = $0 })
                    }
                    .environment(\.dynamicTypeSize, size)
                )
                let scene = try XCTUnwrap(
                    UIApplication.shared.connectedScenes.compactMap {
                        $0 as? UIWindowScene
                    }.first
                )
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(origin: .zero, size: CGSize(width: 393, height: 852))
                window.rootViewController = controller
                window.makeKeyAndVisible()
                defer { window.isHidden = true }
                try await Task.sleep(for: .milliseconds(250))
                controller.view.frame = window.bounds
                controller.view.layoutIfNeeded()

                let contentFrame = switch section {
                case .chat: chatFrame
                case .tasks: tasksFrame
                case .artifacts: artifactsFrame
                }
                let safeBottom = controller.view.safeAreaLayoutGuide.layoutFrame.maxY
                XCTAssertLessThanOrEqual(
                    contentFrame.maxY,
                    safeBottom - CantripHomeLayout.compactContentBottomClearance + 1,
                    "\(section.title) must clear the compact Home tab bar"
                )
                XCTAssertGreaterThan(contentFrame.height, 44)
            }
        }
    }

    private func bottomContentProbe(frame: @escaping (CGRect) -> Void) -> some View {
        VStack(spacing: 0) {
            Spacer()
            Color.blue.opacity(0.2)
                .frame(height: 60)
                .onGeometryChange(for: CGRect.self) {
                    $0.frame(in: .global)
                } action: {
                    frame($0)
                }
        }
    }

    func testHomeNativeTabsAdaptToDuoVerticalBar() async throws {
        #if AGENTGATEWAY_DUO_SDK
        guard #available(iOS 27.1, *) else { throw XCTSkip("Requires the Duo runtime") }
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        guard scene.traitCollection.verticalBarEdge != .unspecified else {
            throw XCTSkip("Run on iPhone Duo in a vertical-bar pose.")
        }
        var composerFrame = CGRect.zero
        let controller = UIHostingController(rootView:
            CantripHomeTabs(selection: .constant(.chat), runningTasks: 1) {
                VStack {
                    Text("Cantrip Home")
                    Spacer()
                    Color.blue.opacity(0.2)
                        .frame(height: 60)
                        .onGeometryChange(for: CGRect.self) {
                            $0.frame(in: .global)
                        } action: {
                            composerFrame = $0
                        }
                }
            } tasks: {
                Text("Tasks")
            } artifacts: {
                Text("Artifacts")
            }
            .environment(\.chatDisplayTraits, ChatDisplayTraits(hasVerticalBar: true))
        )
        let window = UIWindow(windowScene: scene)
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(450))
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()

        let tabBar: UITabBar = try XCTUnwrap(firstSubview(in: controller.view))
        let frame = tabBar.convert(tabBar.bounds, to: window)
        XCTAssertGreaterThan(frame.height, frame.width)
        XCTAssertGreaterThanOrEqual(
            composerFrame.maxY,
            controller.view.safeAreaLayoutGuide.layoutFrame.maxY - 1,
            "Duo's side tabs must not add phone-style bottom clearance"
        )
        if scene.traitCollection.verticalBarEdge == .leading {
            XCTAssertLessThan(frame.midX, window.bounds.midX)
        } else {
            XCTAssertGreaterThan(frame.midX, window.bounds.midX)
        }

        if let directory = ProcessInfo.processInfo.environment[
            "TEST_RUNNER_HOME_DUO_ARTIFACT_DIR"
        ], !directory.isEmpty {
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(
                at: output, withIntermediateDirectories: true
            )
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try XCTUnwrap(image.pngData()).write(
                to: output.appendingPathComponent("cantrip-home-duo-tabs.png")
            )
        }
        #else
        throw XCTSkip("Requires the Duo SDK")
        #endif
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
            case ("DELETE", let value) where value.hasPrefix("/api/v1/home/artifacts/"):
                return (200, Data(#"{"deleted":true}"#.utf8))
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
        try await api.deleteHomeArtifact(id: try XCTUnwrap(artifacts.artifacts.first?.id))
        XCTAssertTrue(requests.contains { $0.0 == "GET" && $0.1 == "/api/v1/home" })
        XCTAssertTrue(requests.contains {
            $0.0 == "DELETE" && $0.1 == "/api/v1/home/artifacts/20000000-0000-0000-0000-000000000001"
        })
    }

    func testTaskReorderMapsListDropsToRelativeMoves() {
        let ids = (0..<4).map { _ in UUID() }
        for source in ids.indices {
            for destination in 0...ids.count {
                let move = CantripHomeTaskReorder.move(
                    ids: ids, fromOffsets: IndexSet(integer: source), toOffset: destination
                )
                var expected = ids
                expected.move(fromOffsets: IndexSet(integer: source), toOffset: destination)
                guard let move else {
                    XCTAssertEqual(expected, ids, "Only no-op drops may be ignored")
                    continue
                }
                var relative = ids
                let moved = relative.remove(at: source)
                let target = relative.firstIndex(of: move.targetID)!
                relative.insert(moved, at: target + (move.after ? 1 : 0))
                XCTAssertEqual(move.id, ids[source])
                XCTAssertEqual(relative, expected, "\(source) -> \(destination)")
            }
        }
        XCTAssertNil(CantripHomeTaskReorder.move(
            ids: ids, fromOffsets: IndexSet([0, 1]), toOffset: 3
        ))
    }

    func testHomeTaskReorderIsOptimisticPersistsAndRollsBack() async throws {
        let client = client()
        let model = CantripRemoteModel(urlSession: client)
        let scheduledID = try XCTUnwrap(UUID(uuidString: "10000000-0000-0000-0000-000000000001"))
        let trackerID = try XCTUnwrap(UUID(uuidString: "10000000-0000-0000-0000-000000000002"))
        var supportsReordering: Bool? = true
        var failMove = false
        var moveBodies: [[String: String]] = []
        CantripHomeRequestProtocol.handler = { request in
            let path = URLComponents(
                url: request.url!, resolvingAgainstBaseURL: false
            )?.percentEncodedPath ?? ""
            switch (request.httpMethod ?? "", path) {
            case ("POST", "/api/v1/home/tasks/\(trackerID.uuidString)/move"):
                XCTAssertEqual(model.homeTasks.map(\.id), [trackerID, scheduledID],
                               "The drop must be visible before the Mac responds")
                XCTAssertTrue(model.isMutating)
                let body = try XCTUnwrap(request.httpBody ?? request.httpBodyStream.map {
                    $0.open()
                    defer { $0.close() }
                    var data = Data()
                    var buffer = [UInt8](repeating: 0, count: 1024)
                    while $0.hasBytesAvailable {
                        let count = $0.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }
                        data.append(buffer, count: count)
                    }
                    return data
                })
                moveBodies.append(try XCTUnwrap(
                    JSONSerialization.jsonObject(with: body) as? [String: String]
                ))
                if failMove { return (500, Data(#"{"error":"Could not save the task on the Mac."}"#.utf8)) }
                return (200, self.tasksPayload(enabled: true, reversed: true, supportsReordering: true))
            case ("GET", "/api/v1/home"):
                return (200, self.homeSessionPayload())
            case ("GET", "/api/v1/home/tasks"):
                return (200, self.tasksPayload(enabled: true, supportsReordering: supportsReordering))
            case ("GET", "/api/v1/home/artifacts"):
                return (200, self.artifactsPayload())
            default:
                return (200, Data(#"{"sessions":[]}"#.utf8))
            }
        }
        addTeardownBlock { @MainActor in
            model.clearConfiguration()
            client.invalidateAndCancel()
            CantripHomeRequestProtocol.handler = nil
        }
        let configured = await model.configure(
            url: "https://cantrip.example", pairingToken: "home-reorder-token", tailscaleOnly: true
        )
        XCTAssertTrue(configured)
        await model.selectHome()
        XCTAssertTrue(model.homeTasksSupportReordering)
        XCTAssertEqual(model.homeTasks.map(\.id), [scheduledID, trackerID])

        let moved = await model.moveHomeTask(trackerID, relativeTo: scheduledID, after: false)
        XCTAssertTrue(moved)
        XCTAssertEqual(moveBodies.last, ["targetID": scheduledID.uuidString, "placement": "before"])
        XCTAssertEqual(model.homeTasks.map(\.id), [trackerID, scheduledID])
        XCTAssertNil(model.homeDataError)
        XCTAssertFalse(model.isMutating)

        // Reset to the server's original order, then prove a failed save rolls back.
        await model.refreshHomeData()
        XCTAssertEqual(model.homeTasks.map(\.id), [scheduledID, trackerID])
        failMove = true
        let failed = await model.moveHomeTask(trackerID, offset: -1)
        XCTAssertFalse(failed)
        XCTAssertEqual(moveBodies.count, 2)
        XCTAssertEqual(model.homeTasks.map(\.id), [scheduledID, trackerID])
        XCTAssertNotNil(model.homeDataError)

        supportsReordering = nil
        await model.refreshHomeData()
        XCTAssertFalse(model.homeTasksSupportReordering, "Older Macs do not advertise reordering")
        let unsupported = await model.moveHomeTask(trackerID, offset: -1)
        XCTAssertFalse(unsupported)
        XCTAssertEqual(moveBodies.count, 2, "An older Mac must not receive a move request")
        XCTAssertEqual(model.homeTasks.map(\.id), [scheduledID, trackerID])
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
            if request.httpMethod == "DELETE",
               path.hasPrefix("/api/v1/home/artifacts/") {
                return (200, Data(#"{"deleted":true}"#.utf8))
            }
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

        let artifact = try XCTUnwrap(model.homeArtifacts.first)
        let deleted = await model.deleteHomeArtifact(artifact)
        XCTAssertTrue(deleted)
        XCTAssertTrue(model.homeArtifacts.isEmpty)
        XCTAssertEqual(artifactPublishes, 1)
    }

    func testHomeHandoffCardsDecodeAndOpenTheirTab() async throws {
        let bassID = "40000000-0000-0000-0000-000000000001"
        let otherID = "40000000-0000-0000-0000-000000000002"
        let client = client()
        let model = CantripRemoteModel(urlSession: client)
        CantripHomeRequestProtocol.handler = { request in
            let path = URLComponents(
                url: request.url!, resolvingAgainstBaseURL: false
            )?.percentEncodedPath ?? ""
            switch path {
            case "/api/v1/home":
                return (200, self.homeSessionPayload(messages: self.handoffMessages(bassID: bassID)))
            case "/api/v1/home/tasks": return (200, self.tasksPayload(enabled: true))
            case "/api/v1/home/artifacts": return (200, self.artifactsPayload())
            case "/api/v1/sessions": return (200, self.tabListPayload([otherID, bassID]))
            case "/api/v1/sessions/\(bassID)": return (200, self.tabPayload(id: bassID))
            case "/api/v1/sessions/\(otherID)": return (200, self.tabPayload(id: otherID))
            default: return (200, Data(#"{"sessions":[]}"#.utf8))
            }
        }
        addTeardownBlock { @MainActor in
            model.setAppActive(false)
            model.clearConfiguration()
            client.invalidateAndCancel()
            CantripHomeRequestProtocol.handler = nil
        }
        let configured = await model.configure(
            url: "https://cantrip.example", pairingToken: "handoff-token", tailscaleOnly: true
        )
        XCTAssertTrue(configured)
        model.setAppActive(true)
        await model.refreshNow()
        model.setAppActive(false)
        XCTAssertEqual(model.sessions.map(\.id), [otherID, bassID])
        await model.selectSession(otherID)
        await model.selectHome()
        let transcript = model.selectedSession?.transcript ?? []
        XCTAssertNil(transcript.first { $0.id == "h1" }?.delegations,
                     "Plain Home answers carry no handoff cards")
        let handoffs = try XCTUnwrap(transcript.first { $0.id == "h2" }?.delegations)
        XCTAssertEqual(handoffs.first, CantripRemoteDelegation(
            id: "d1", tabID: bassID, tabTitle: "Bass Compass",
            summary: "Fix lineup sorting",
            prompt: "Fix the Bass Compass lineup sorting so headliners appear first.",
            status: .completed, startedAt: 100, finishedAt: 160,
            result: "Headliners now sort first."
        ))
        XCTAssertEqual(handoffs.count, 2, "A malformed card must not drop the message")
        XCTAssertEqual(handoffs[1].status, .running)
        XCTAssertEqual(handoffs[1].tabTitle, "")
        XCTAssertFalse(handoffs[1].id.isEmpty)

        model.prepareToOpenTab(bassID)
        await model.selectRegularSession()
        XCTAssertFalse(model.isHomeSelected)
        XCTAssertEqual(model.selectedSessionID, bassID,
                       "Open tab must win over the previously selected Remote tab")
    }

    func testHandoffCardsFitNarrowAndAccessibilityWidths() {
        for dynamicType in [DynamicTypeSize.large, .accessibility5] {
            for width in [CGFloat(320), 393] {
                let controller = UIHostingController(rootView:
                    CantripHandoffStack(handoffs: sampleHandoffs(), onOpenTab: { _ in })
                        .environment(\.dynamicTypeSize, dynamicType)
                        .frame(width: width)
                )
                let fitted = controller.sizeThatFits(
                    in: CGSize(width: width, height: .greatestFiniteMagnitude)
                )
                XCTAssertLessThanOrEqual(fitted.width, width + 0.5)
                XCTAssertGreaterThan(fitted.height, 200)
            }
        }
    }

    func testHandoffCardsLeaveNarrationInTheTab() throws {
        let now = Date().timeIntervalSince1970
        let narration = "I'll start with my Cantrip notes, then map how Home depends on the Copilot CLI. "
            + "Now the rest of the Home section, then the tests, the bridge and the staged build."
        let plain = CantripRemoteDelegation(
            id: "a", tabID: "tab", tabTitle: "Cantrip", summary: "Make Home backend-agnostic",
            status: .completed, startedAt: now - 600, finishedAt: now - 60
        )
        let verbose = CantripRemoteDelegation(
            id: "a", tabID: "tab", tabTitle: "Cantrip", summary: "Make Home backend-agnostic",
            status: .completed, startedAt: now - 600, finishedAt: now - 60,
            latestStatus: narration, result: narration + narration, error: "The tab's run failed."
        )
        for dynamicType in [DynamicTypeSize.large, .accessibility3] {
            func height(_ handoff: CantripRemoteDelegation) -> CGFloat {
                UIHostingController(rootView:
                    CantripHandoffCard(handoff: handoff, onOpenTab: { _ in })
                        .environment(\.dynamicTypeSize, dynamicType)
                        .frame(width: 393)
                ).sizeThatFits(in: CGSize(width: 393, height: CGFloat.greatestFiniteMagnitude)).height
            }
            XCTAssertEqual(height(verbose), height(plain), accuracy: 0.5,
                           "Narration, results and errors stay in the tab at \(dynamicType)")
            if dynamicType == .large {
                XCTAssertLessThanOrEqual(height(plain), 110, "A handoff card stays a couple of lines tall")
            }
        }

        let decoded = try JSONDecoder().decode([CantripRemoteDelegation].self, from: Data("""
        [{"id":"q","tabID":"t","status":"running","needsInput":true},
         {"id":"o","tabID":"t","status":"running","latestStatus":"Waiting for your input"},
         {"id":"w","tabID":"t","status":"running","latestStatus":"Running xcodebuild test","needsInput":"yes"},
         {"id":"c","tabID":"t","status":"completed","needsInput":true}]
        """.utf8))
        let cards = decoded.map { CantripHandoffCard(handoff: $0) }
        XCTAssertEqual(decoded.map(\.needsInput), [true, false, false, true])
        XCTAssertEqual(cards.map(\.needsAnswer), [true, true, false, false],
                       "Running tabs that wait on the user say so, including older Macs")
        XCTAssertEqual(cards.map(\.statusText),
                       ["Needs your answer", "Needs your answer", "Working in tab", "Done in tab"])
    }

    func testHomeHandoffCardScreenshots() async throws {
        let directory = ProcessInfo.processInfo.environment["TEST_RUNNER_HOME_ARTIFACT_DIR"]
        guard let directory, !directory.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_HOME_ARTIFACT_DIR to render Home handoff cards.")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let variants: [(String, UIUserInterfaceStyle, DynamicTypeSize)] = [
            ("light", .light, .large), ("dark", .dark, .large), ("ax", .light, .accessibility3),
        ]
        for (name, style, dynamicType) in variants {
            let controller = UIHostingController(rootView:
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("The Bass Compass tab is taking this.")
                        CantripHandoffStack(handoffs: sampleHandoffs(), onOpenTab: { _ in })
                    }
                    .padding(16)
                }
                .environment(\.dynamicTypeSize, dynamicType)
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
                to: output.appendingPathComponent("cantrip-home-handoffs-\(name).png")
            )
        }
    }

    private func sampleHandoffs() -> [CantripRemoteDelegation] {
        let now = Date().timeIntervalSince1970
        return [
            .init(id: "running", tabID: "tab-1", tabTitle: "Bass Compass",
                  summary: "Fix lineup sorting", status: .running, startedAt: now - 95,
                  latestStatus: "Running xcodebuild test"),
            .init(id: "asking", tabID: "tab-3", tabTitle: "Cantrip",
                  summary: "Make Home's guardrails backend-agnostic", status: .running,
                  startedAt: now - 240, latestStatus: "Needs your answer", needsInput: true),
            .init(id: "done", tabID: "tab-1", tabTitle: "Bass Compass",
                  summary: "Collapse past sets in the lineup", status: .completed,
                  startedAt: now - 900, finishedAt: now - 420,
                  result: "Past sets now collapse under an Earlier today header. Tests pass, and the change is pushed to master as 1a2b3c4 for the next OTA update."),
            .init(id: "stopped", tabID: "tab-2", tabTitle: "Plexible",
                  summary: "Fix the player scrubber", status: .cancelled,
                  startedAt: now - 300, finishedAt: now - 240, error: "Stopped in the tab."),
        ]
    }

    private func handoffMessages(bassID: String) -> String {
        """
        [{"id":"h0","role":"user","text":"How many users does Bass Compass have?","thinking":"","activities":[]},
        {"id":"h1","role":"assistant","text":"Bass Compass has 109 users.","thinking":"","activities":[]},
        {"id":"h2","role":"assistant","text":"The Bass Compass tab is taking this.","thinking":"",
        "activities":[],"delegations":[
        {"id":"d1","tabID":"\(bassID)","tabTitle":"Bass Compass","summary":"Fix lineup sorting",
        "prompt":"Fix the Bass Compass lineup sorting so headliners appear first.",
        "status":"completed","startedAt":100,"finishedAt":160,"result":"Headliners now sort first."},
        {"tabID":"\(bassID)","status":"paused","tabTitle":7}]}]
        """
    }

    private func tabListPayload(_ ids: [String]) -> Data {
        let tabs = ids.map { id in
            """
            {"id":"\(id)","title":"Tab \(id.suffix(1))","workdir":"/tmp","isStreaming":false,
            "canResume":false,"councilMode":false,"queuedCount":0,"supportsAutoDelivery":true}
            """
        }
        return Data(#"{"sessions":[\#(tabs.joined(separator: ","))]}"#.utf8)
    }

    private func tabPayload(id: String) -> Data {
        Data("""
        {"session":{"id":"\(id)","title":"Tab \(id.suffix(1))","workdir":"/tmp",
        "isStreaming":false,"canResume":false,"councilMode":false,"queuedCount":0,
        "status":null,"messages":[],"queued":[],"supportsAutoDelivery":true}}
        """.utf8)
    }

    func testHomeBackgroundListsRunsCountsBadgeAndOpensLog() async throws {
        let client = client()
        let model = CantripRemoteModel(urlSession: client)
        var supportsRuns = true
        var paths: [String] = []
        CantripHomeRequestProtocol.handler = { request in
            let path = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .percentEncodedPath ?? ""
            paths.append(path)
            switch path {
            case "/api/v1/home":
                return (200, self.homeSessionPayload(
                    messages: self.backgroundWatcher,
                    extra: supportsRuns ? #","supportsBackgroundRuns":true,"backgroundActiveCount":2"# : ""
                ))
            case "/api/v1/home/tasks": return (200, self.tasksPayload(enabled: true))
            case "/api/v1/home/artifacts": return (200, self.artifactsPayload())
            case "/api/v1/home/background": return (200, self.backgroundPayload())
            case "/api/v1/sessions/\(self.backgroundID)":
                return (200, Data("""
                {"session":{"id":"\(self.backgroundID)","title":"Cantrip Home background",
                "workdir":"/tmp","isStreaming":false,"canResume":false,"councilMode":false,
                "queuedCount":0,"status":null,"messages":[],"queued":[],"isLocked":true,
                "isCantripHomeBackground":true}}
                """.utf8))
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
        XCTAssertEqual(model.selectedSession?.supportsBackgroundRuns, true)
        XCTAssertEqual(
            CantripHomeBackgroundCount.active(
                transcript: model.selectedSession?.transcript ?? [], session: model.selectedSession
            ),
            3, "The badge counts the chat's live watcher plus the Mac's running and queued runs"
        )

        await model.refreshHomeBackground()
        let snapshot = try XCTUnwrap(model.homeBackground)
        XCTAssertEqual(snapshot.sessionID, backgroundID)
        XCTAssertEqual(snapshot.activity, "Reading the incident file")
        XCTAssertEqual(snapshot.queued.map(\.label), ["Daily trip tracker"])
        XCTAssertEqual(snapshot.runs.map(\.label), [
            "Automated Bass Compass Ingestion Incident", "Daily interview tracker", "Daily trip tracker",
        ])
        XCTAssertTrue(snapshot.runs[0].isIncident && snapshot.runs[0].isRunning)
        XCTAssertNil(snapshot.runs[0].finishedAt)
        XCTAssertEqual(snapshot.runs[1].taskID, UUID(uuidString: "10000000-0000-0000-0000-000000000002"))
        XCTAssertEqual(snapshot.runs[2].status, "failed")

        let finished = CantripHomeBackgroundRunRow(run: snapshot.runs[1], isExpanded: .constant(false))
        XCTAssertEqual(finished.statusText, "Done")
        XCTAssertTrue(finished.detail(now: Date()).hasPrefix("Scheduled task · Done "))
        XCTAssertTrue(finished.detail(now: Date()).hasSuffix("· took 3m 20s"))
        let running = CantripHomeBackgroundRunRow(run: snapshot.runs[0], isExpanded: .constant(false))
        XCTAssertTrue(running.detail(now: Date()).hasPrefix("Incident · Running for 1m"))

        model.prepareToOpenHomeBackgroundLog()
        await model.selectRegularSession()
        XCTAssertFalse(model.isHomeSelected)
        XCTAssertEqual(model.selectedSessionID, backgroundID,
                       "Full Log opens the background conversation even though it is not a tab")
        await model.selectRegularSession()
        XCTAssertNotEqual(model.selectedSessionID, backgroundID, "The log opens once, not on every lane switch")

        supportsRuns = false
        await model.selectHome()
        paths.removeAll()
        await model.refreshHomeBackground()
        XCTAssertFalse(paths.contains("/api/v1/home/background"),
                       "Older Macs without the run list are never asked for it")
        XCTAssertEqual(
            CantripHomeBackgroundCount.active(
                transcript: model.selectedSession?.transcript ?? [], session: model.selectedSession
            ),
            1
        )
    }

    func testHomeBackgroundParallelRunsStopAndHandoffs() async throws {
        let client = client()
        let model = CantripRemoteModel(urlSession: client)
        var stopped = false
        var requests: [(method: String, path: String)] = []
        CantripHomeRequestProtocol.handler = { request in
            let path = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .percentEncodedPath ?? ""
            requests.append((request.httpMethod ?? "GET", path))
            switch path {
            case "/api/v1/home":
                return (200, self.homeSessionPayload(
                    extra: #","supportsBackgroundRuns":true,"backgroundActiveCount":3"#
                ))
            case "/api/v1/home/tasks": return (200, self.tasksPayload(enabled: true))
            case "/api/v1/home/artifacts": return (200, self.artifactsPayload())
            case "/api/v1/home/background": return (200, self.parallelBackgroundPayload(stopped: stopped))
            case "/api/v1/home/background/30000000-0000-0000-0000-000000000011/stop":
                stopped = true
                return (200, self.parallelBackgroundPayload(stopped: true))
            case "/api/v1/sessions/\(self.runSessionID)":
                return (200, Data("""
                {"session":{"id":"\(self.runSessionID)","title":"Cantrip Home background",
                "workdir":"/tmp","isStreaming":true,"canResume":false,"councilMode":false,
                "queuedCount":0,"status":"Reading Mail","messages":[],"queued":[],"isLocked":true,
                "isCantripHomeBackground":true}}
                """.utf8))
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
        await model.refreshHomeBackground()
        let snapshot = try XCTUnwrap(model.homeBackground)
        XCTAssertEqual(snapshot.maxParallel, 3)
        XCTAssertEqual(snapshot.supportsStop, true)
        XCTAssertNil(snapshot.activity, "Parallel Macs send each run's own activity")

        let bills = snapshot.runs[0]
        XCTAssertEqual(bills.activity, "Reading Mail")
        XCTAssertEqual(bills.canStop, true)
        XCTAssertEqual(bills.sessionID, runSessionID)
        XCTAssertFalse(bills.isHandedOff)
        let billsRow = CantripHomeBackgroundRunRow(run: bills, isExpanded: .constant(false))
        XCTAssertTrue(billsRow.detail(now: Date()).hasPrefix("Scheduled task · Running for 1m"))

        let handed = snapshot.runs[1]
        XCTAssertTrue(handed.isHandedOff)
        XCTAssertEqual(handed.tabHandoff?.tabTitle, "Bass Compass")
        XCTAssertEqual(handed.tabHandoff?.status, .queued)
        XCTAssertEqual(handed.tabHandoff?.tabID, bassTabID)
        let handedRow = CantripHomeBackgroundRunRow(run: handed, isExpanded: .constant(false))
        let handedDetail = handedRow.detail(now: Date())
        XCTAssertTrue(handedDetail.hasPrefix("Incident · Queued in Bass Compass for 3m"), handedDetail)
        XCTAssertTrue(handedDetail.hasSuffix("· reported 2 times"), handedDetail)

        let skipped = CantripHomeBackgroundRunRow(run: snapshot.runs[2], isExpanded: .constant(false))
        XCTAssertEqual(skipped.statusText, "Skipped")
        XCTAssertTrue(skipped.detail(now: Date()).hasPrefix("Incident · Skipped "))

        let waiting = CantripHomeBackgroundQueuedRow(item: snapshot.queued[0])
        XCTAssertEqual(waiting.detail,
                       "Scheduled task · Waiting for Bills and subscriptions monitor (until 8:30 AM)")

        let didStop = await model.stopHomeBackgroundRun(bills.id)
        XCTAssertTrue(didStop)
        XCTAssertTrue(requests.contains {
            $0.method == "POST"
                && $0.path == "/api/v1/home/background/30000000-0000-0000-0000-000000000011/stop"
        })
        XCTAssertEqual(model.homeBackground?.runs.first?.status, "cancelled",
                       "Stop refreshes the list from the Mac's reply")
        XCTAssertNil(model.homeBackgroundError)

        model.prepareToOpenHomeRun(sessionID: runSessionID)
        await model.selectRegularSession()
        XCTAssertEqual(model.selectedSessionID, runSessionID,
                       "Open shows a live hidden run even though it is not a tab")
    }

    func testHomeBackgroundStopNeedsASupportingMac() async throws {
        let client = client()
        let model = CantripRemoteModel(urlSession: client)
        var stopRequests = 0
        CantripHomeRequestProtocol.handler = { request in
            let path = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .percentEncodedPath ?? ""
            if path.hasSuffix("/stop") { stopRequests += 1 }
            switch path {
            case "/api/v1/home":
                return (200, self.homeSessionPayload(
                    extra: #","supportsBackgroundRuns":true,"backgroundActiveCount":2"#
                ))
            case "/api/v1/home/background": return (200, self.backgroundPayload())
            default: return (200, Data(#"{"sessions":[]}"#.utf8))
            }
        }
        addTeardownBlock { @MainActor in
            model.clearConfiguration()
            client.invalidateAndCancel()
            CantripHomeRequestProtocol.handler = nil
        }
        _ = await model.configure(
            url: "https://cantrip.example", pairingToken: "home-token", tailscaleOnly: true
        )
        await model.selectHome()
        await model.refreshHomeBackground()
        let run = try XCTUnwrap(model.homeBackground?.runs.first)
        XCTAssertNil(run.canStop)
        XCTAssertEqual(run.route, nil)
        let didStop = await model.stopHomeBackgroundRun(run.id)
        XCTAssertFalse(didStop)
        XCTAssertEqual(stopRequests, 0, "Older Macs without per-run Stop are never asked to stop")
        let row = CantripHomeBackgroundRunRow(run: run, activity: model.homeBackground?.activity,
                                              isExpanded: .constant(false))
        XCTAssertTrue(row.detail(now: Date()).hasPrefix("Incident · Running for 1m"))
    }

    func testHomeBackgroundScreenshots() async throws {
        let directory = ProcessInfo.processInfo.environment["TEST_RUNNER_HOME_ARTIFACT_DIR"]
        guard let directory, !directory.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_HOME_ARTIFACT_DIR to render the Home Background sheet.")
        }
        let client = client()
        let model = CantripRemoteModel(urlSession: client)
        CantripHomeRequestProtocol.handler = { request in
            switch URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? "" {
            case "/api/v1/home":
                return (200, self.homeSessionPayload(
                    messages: self.backgroundWatcher,
                    extra: #","supportsBackgroundRuns":true,"backgroundActiveCount":2"#
                ))
            case "/api/v1/home/tasks": return (200, self.tasksPayload(enabled: true))
            case "/api/v1/home/artifacts": return (200, self.artifactsPayload())
            case "/api/v1/home/background":
                return (200, ProcessInfo.processInfo.environment["HOME_BACKGROUND_LEGACY"] == "1"
                    ? self.backgroundPayload() : self.parallelBackgroundPayload())
            case "/api/v1/copilot/usage": return (200, Data(#"{"isRefreshing":false}"#.utf8))
            default: return (200, Data(#"{"sessions":[]}"#.utf8))
            }
        }
        let env = HermesEnv()
        let originalLane = env.executionLane
        addTeardownBlock { @MainActor in
            env.select(originalLane)
            model.clearConfiguration()
            client.invalidateAndCancel()
            CantripHomeRequestProtocol.handler = nil
        }
        let configured = await model.configure(
            url: "https://cantrip.example", pairingToken: "home-token", tailscaleOnly: true
        )
        XCTAssertTrue(configured)
        env.select(.home)
        await model.selectHome()
        await model.refreshHomeBackground()
        XCTAssertNotNil(model.homeBackground)

        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        func capture(_ view: some View, _ name: String, style: UIUserInterfaceStyle,
                     size: DynamicTypeSize = .large) async throws {
            let controller = UIHostingController(rootView: view.dynamicTypeSize(size))
            controller.overrideUserInterfaceStyle = style
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: CGSize(width: 393, height: 852))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            try await Task.sleep(for: .milliseconds(500))
            controller.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try XCTUnwrap(image.pngData()).write(to: output.appendingPathComponent("\(name).png"))
        }
        for (name, style) in [("light", UIUserInterfaceStyle.light), ("dark", .dark)] {
            try await capture(
                CantripHomeBackgroundView(remote: model, openLog: {}, openSession: { _ in },
                                          openTab: { _ in }),
                "cantrip-home-background-\(name)", style: style
            )
            try await capture(ChatView(env: env, remote: model), "cantrip-home-background-header-\(name)",
                              style: style)
        }
        try await capture(
            CantripHomeBackgroundView(remote: model, openLog: {}, openSession: { _ in },
                                      openTab: { _ in }),
            "cantrip-home-background-ax", style: .light, size: .accessibility3
        )
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
                CantripHomeTabs(selection: .constant(.tasks), runningTasks: 1) {
                    Color.clear
                } tasks: {
                    NavigationStack {
                        CantripHomeTasksView(remote: model, openChat: { _ in })
                    }
                } artifacts: {
                    Color.clear
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
                CantripHomeTabs(selection: .constant(.artifacts), runningTasks: 0) {
                    Color.clear
                } tasks: {
                    Color.clear
                } artifacts: {
                    NavigationStack {
                        CantripHomeArtifactsView(remote: model, openChat: { _ in })
                    }
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

    private func homeSessionPayload(messages: String = "[]", extra: String = "") -> Data {
        Data("""
        {"session":{"id":"\(homeID)","title":"Cantrip Home","workdir":"/tmp",
        "isStreaming":false,"canResume":false,"councilMode":false,"queuedCount":0,
        "status":null,"messages":\(messages),"supportsImageAttachments":true,"queued":[],
        "supportsAutoDelivery":true,"isLocked":true,"isCantripHome":true,
        "supportsModelSettings":true,"supportsPagedHistory":true\(extra)}}
        """.utf8)
    }

    private let backgroundID = "231C484E-0E50-43E0-9ADF-4295F3AC8956"

    private let backgroundWatcher = #"""
    [{"id":"w","role":"assistant","text":"Watching the build.","thinking":"","activities":[],
      "subagents":[{"id":"call_w","agentID":"a1","name":"watch-testflight","agentType":"task",
      "summary":"Wait for TestFlight processing","background":true,"status":"running",
      "startedAt":1790501259,"canCancel":true,"latestMessage":"Build 100118 is processing."}]}]
    """#

    private let runSessionID = "40000000-0000-0000-0000-0000000000AA"
    private let bassTabID = "50000000-0000-0000-0000-0000000000BB"

    /// A Mac that runs background jobs in parallel hidden sessions and hands incidents to tabs.
    private func parallelBackgroundPayload(stopped: Bool = false) -> Data {
        let now = Date().timeIntervalSinceReferenceDate.rounded(.down)
        let epoch = Date().timeIntervalSince1970.rounded(.down)
        let bills = stopped
            ? #""status":"cancelled","summary":"Stopped.","finishedAt":\#(now - 5),"canStop":false"#
            : #""status":"running","summary":"","activity":"Reading Mail","canStop":true,"sessionID":"\#(runSessionID)""#
        return Data("""
        {"sessionID":"\(backgroundID)","revision":"\(stopped ? "b3" : "b2")","maxParallel":3,
         "runningCount":\(stopped ? 1 : 2),"supportsStop":true,
         "queued":[{"id":"30000000-0000-0000-0000-000000000013","kind":"task",
           "label":"Personal operations briefing",
           "reason":"Waiting for Bills and subscriptions monitor (until 8:30 AM)"}],
         "runs":[
          {"id":"30000000-0000-0000-0000-000000000011","kind":"task","label":"Bills and subscriptions monitor",
           "taskID":"10000000-0000-0000-0000-000000000002","startedAt":\(now - 70),"route":"hidden",
           "handoffs":[],\(bills)},
          {"id":"30000000-0000-0000-0000-000000000012","kind":"incident",
           "label":"Automated Bass Compass Ingestion Incident","startedAt":\(now - 200),
           "status":"running","summary":"","route":"tab","repeats":1,"canStop":true,
           "activity":"Queued in Bass Compass",
           "handoffs":[{"id":"60000000-0000-0000-0000-000000000001","tabID":"\(bassTabID)",
             "tabTitle":"Bass Compass","summary":"Automated Bass Compass Ingestion Incident",
             "prompt":"AUTOMATED BASS COMPASS INGESTION INCIDENT","status":"queued",
             "startedAt":\(epoch - 200),"latestStatus":"Waiting for the tab's current work to finish."}]},
          {"id":"30000000-0000-0000-0000-000000000014","kind":"incident",
           "label":"Automated Bass Compass Ingestion Incident","startedAt":\(now - 900),
           "finishedAt":\(now - 900),"status":"skipped","route":"hidden","canStop":false,
           "summary":"Already resolved: the Insomniac timeouts were transient."}
         ]}
        """.utf8)
    }

    private func backgroundPayload() -> Data {
        let now = Date().timeIntervalSinceReferenceDate.rounded(.down)
        return Data("""
        {"sessionID":"\(backgroundID)","revision":"b1","activity":"Reading the incident file",
         "queued":[{"id":"30000000-0000-0000-0000-000000000003","kind":"task","label":"Daily trip tracker"}],
         "runs":[
          {"id":"30000000-0000-0000-0000-000000000001","kind":"incident",
           "label":"Automated Bass Compass Ingestion Incident","startedAt":\(now - 95),
           "status":"running","summary":""},
          {"id":"30000000-0000-0000-0000-000000000002","kind":"task",
           "label":"Daily interview tracker","taskID":"10000000-0000-0000-0000-000000000002",
           "startedAt":\(now - 3_900),
           "finishedAt":\(now - 3_700),
           "status":"succeeded",
           "summary":"Two new emails. **Rippling** booked an intro call for Thu Oct 8 at 9:30 AM, and Anthropic sent a follow-up for Software Engineer, Business Technology.\\n\\n- Rippling added as the third upcoming call\\n- Bloomberg moved to Applied"},
          {"id":"30000000-0000-0000-0000-000000000004","kind":"task","label":"Daily trip tracker",
           "startedAt":\(now - 90_000),
           "finishedAt":\(now - 89_900),
           "status":"failed","summary":"Calendar access timed out."}
         ]}
        """.utf8)
    }

    private func firstSubview<T: UIView>(in view: UIView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match: T = firstSubview(in: child) { return match }
        }
        return nil
    }

    private func firstViewController<T: UIViewController>(
        in controller: UIViewController
    ) -> T? {
        if let match = controller as? T { return match }
        for child in controller.children {
            if let match: T = firstViewController(in: child) { return match }
        }
        return nil
    }

    private func tasksPayload(
        enabled: Bool, reversed: Bool = false, supportsReordering: Bool? = nil
    ) -> Data {
        var tasks = [
            String(decoding: taskPayload(enabled: enabled), as: UTF8.self),
            String(decoding: workspaceTaskPayload(), as: UTF8.self),
        ]
        if reversed { tasks.reverse() }
        let flag = supportsReordering.map { #","supportsReordering":\#($0)"# } ?? ""
        return Data("""
        {"tasks":[\(tasks.joined(separator: ",\n"))],
        "revision":"task-revision"\(flag)}
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
