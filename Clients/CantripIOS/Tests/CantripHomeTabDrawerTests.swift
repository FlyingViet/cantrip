import SwiftUI
import UIKit
import XCTest
@testable import Hermes

private final class HomeTabsRequestProtocol: URLProtocol {
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

/// Cantrip Home's tab drawer, tab header and the merged Remote lane.
@MainActor
final class CantripHomeTabDrawerTests: XCTestCase {
    private let homeID = "7EAE0CE5-8C8B-4652-9FD0-214867A90E5D"
    private let plexID = "60000000-0000-0000-0000-000000000001"
    private let bassID = "60000000-0000-0000-0000-000000000002"
    private let newID = "60000000-0000-0000-0000-000000000003"

    private func session(
        _ id: String, _ title: String, streaming: Bool = false, status: String? = nil,
        preview: String? = nil, inputs: Int = 0, queued: Int = 0, age: TimeInterval? = nil,
        workdir: String = "/Users/me/Coding/Plexa", locked: Bool = false
    ) -> CantripRemoteSession {
        var session = CantripRemoteSession(
            id: id, title: title, workdir: workdir, isStreaming: streaming, canResume: false,
            councilMode: false, queuedCount: queued, status: status, messages: nil,
            supportsImageAttachments: true, queued: nil, isLocked: locked,
            supportsTabMetadata: true, supportsTabReordering: true
        )
        session.pendingInputCount = inputs
        session.preview = preview
        session.lastActivityAt = age.map { Date().timeIntervalSince1970 - $0 }
        return session
    }

    func testAgesReadShortAndSpokenWithoutFutureTimes() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(CantripRelativeTime.short(now.addingTimeInterval(-20), now: now), "now")
        XCTAssertEqual(CantripRelativeTime.short(now.addingTimeInterval(30), now: now), "now",
                       "A Mac clock slightly ahead never shows a negative age")
        XCTAssertEqual(CantripRelativeTime.short(now.addingTimeInterval(-61), now: now), "1m")
        XCTAssertEqual(CantripRelativeTime.short(now.addingTimeInterval(-2 * 3_600 - 5), now: now), "2h")
        XCTAssertEqual(CantripRelativeTime.short(now.addingTimeInterval(-86_400), now: now), "1d")
        XCTAssertEqual(CantripRelativeTime.short(now.addingTimeInterval(-15 * 86_400), now: now), "2w")
        XCTAssertEqual(CantripRelativeTime.spoken(now.addingTimeInterval(-10), now: now), "just now")
        XCTAssertTrue(CantripRelativeTime.spoken(now.addingTimeInterval(-7_200), now: now).contains("2 hours"))
    }

    func testRowsShowLiveStatusWhileWorkingElseTheLatestOutcome() {
        XCTAssertEqual(CantripTabRowText.detail(for: session(plexID, "Plexible", streaming: true,
                                                             status: "Running the cold-launch baseline")),
                       .init(text: "Running the cold-launch baseline", isActive: true))
        XCTAssertEqual(CantripTabRowText.detail(for: session(plexID, "Plexible", streaming: true))?.text,
                       "Working…")
        XCTAssertEqual(CantripTabRowText.detail(for: session(plexID, "Plexible", streaming: true, inputs: 1)),
                       .init(text: "Needs your input", isActive: true))
        XCTAssertEqual(CantripTabRowText.detail(for: session(bassID, "Bass", preview: "Builds tab shipped")),
                       .init(text: "Builds tab shipped", isActive: false))
        XCTAssertEqual(CantripTabRowText.detail(for: session(bassID, "Bass", preview: "Shipped", queued: 2))?.text,
                       "2 queued · Shipped")
        XCTAssertNil(CantripTabRowText.detail(for: session(bassID, "Bass", preview: "  ")),
                     "Older Macs send no preview; the row keeps one line")

        XCTAssertEqual(CantripTabRowText.state(for: session(plexID, "P", streaming: true), connection: .connected),
                       .init(text: "Working", isActive: true))
        XCTAssertEqual(CantripTabRowText.state(for: session(plexID, "P", queued: 1), connection: .connected).text,
                       "1 queued")
        XCTAssertEqual(CantripTabRowText.state(for: session(plexID, "P"), connection: .connected).text, "Idle")
        XCTAssertEqual(CantripTabRowText.state(for: session(plexID, "P", streaming: true),
                                               connection: .disconnected).text,
                       "Disconnected", "A stale Working state is not shown while offline")

        let tabs = [session(plexID, "Plexible", streaming: true),
                    session(bassID, "Bass", inputs: 2), session(newID, "New", streaming: true)]
        XCTAssertEqual(CantripHomeTabCounts.working(in: tabs), 2)
        XCTAssertEqual(CantripHomeTabCounts.needingInput(in: tabs), 1)
        let value = session(bassID, "Bass Compass", preview: "Resolved", age: 7_300, locked: true)
            .tabRowAccessibilityValue
        XCTAssertTrue(value.hasPrefix("Locked, Resolved, "), value)
        XCTAssertTrue(value.contains("2 hours"), value)
    }

    func testSearchMatchesNameFolderAndOutcome() {
        let tabs = [
            session(plexID, "Plexible", preview: "Cold launch faster", workdir: "/Users/me/Coding/Plexa"),
            session(bassID, "Bass Compass", preview: "Resolved ingestion", workdir: "/Users/me/bass-compass"),
        ]
        XCTAssertEqual(CantripHomeTabSearch.filter(tabs, query: "").map(\.id), [plexID, bassID])
        XCTAssertEqual(CantripHomeTabSearch.filter(tabs, query: "plexa").map(\.id), [plexID])
        XCTAssertEqual(CantripHomeTabSearch.filter(tabs, query: "INGESTION").map(\.id), [bassID])
        XCTAssertEqual(CantripHomeTabSearch.filter(tabs, query: "bass resolved").map(\.id), [bassID])
        XCTAssertTrue(CantripHomeTabSearch.filter(tabs, query: "bass faster").isEmpty)
    }

    func testReorderingMapsDropsToRelativeMoves() {
        var tabs = [session(plexID, "A"), session(bassID, "B"), session(newID, "C")]
        XCTAssertEqual(CantripTabReorder.move(tabs, fromOffsets: IndexSet(integer: 0), toOffset: 3)?.targetID, newID)
        XCTAssertEqual(CantripTabReorder.move(tabs, fromOffsets: IndexSet(integer: 2), toOffset: 0)?.after, false)
        XCTAssertNil(CantripTabReorder.move(tabs, fromOffsets: IndexSet(integer: 1), toOffset: 2))
        tabs[0].supportsTabReordering = nil
        XCTAssertNil(CantripTabReorder.move(tabs, fromOffsets: IndexSet(integer: 0), toOffset: 3))
    }

    private func client() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HomeTabsRequestProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func configuredModel(created: @escaping () -> Void = {}) async throws -> CantripRemoteModel {
        let client = client()
        let model = CantripRemoteModel(urlSession: client)
        let finished = Date().timeIntervalSince1970 - 3 * 3_600
        HomeTabsRequestProtocol.handler = { [self] request in
            let path = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
            switch (request.httpMethod ?? "GET", path) {
            case ("GET", "/api/v1/home"): return (200, homePayload())
            case (_, "/api/v1/home/tasks"): return (200, Data(#"{"tasks":[]}"#.utf8))
            case (_, "/api/v1/home/artifacts"): return (200, Data(#"{"artifacts":[]}"#.utf8))
            case ("GET", "/api/v1/home/background"): return (200, buildQueueBackgroundPayload())
            case ("GET", "/api/v1/sessions"):
                return (200, Data("""
                {"sessions":[
                 {"id":"\(plexID)","title":"Plexible","workdir":"/tmp","isStreaming":true,"canResume":false,
                  "councilMode":false,"queuedCount":0,"status":"Running the cold-launch baseline",
                  "lastActivityAt":\(Date().timeIntervalSince1970 - 30),"supportsTabReordering":true,"backgroundTaskCount":2},
                 {"id":"\(bassID)","title":"Bass Compass","workdir":"/tmp","isStreaming":false,"canResume":false,
                  "councilMode":false,"queuedCount":0,"lastActivityAt":\(finished),
                  "preview":"Resolved: ingestion dry-run incident","supportsTabReordering":true}],
                 "home":{"id":"\(homeID)","title":"Cantrip Home","workdir":"/tmp","isStreaming":false,
                  "canResume":false,"councilMode":false,"queuedCount":0,"isCantripHome":true,
                  "pendingInputCount":1,"supportsBackgroundRuns":true,"backgroundActiveCount":3,
                  "buildsRunning":2,"buildsWaiting":1}}
                """.utf8))
            case ("POST", "/api/v1/sessions"):
                created()
                return (201, Data("""
                {"session":{"id":"\(newID)","title":"New tab","workdir":"/tmp","isStreaming":false,
                "canResume":false,"councilMode":false,"queuedCount":0,"status":null,"messages":[],"queued":[]}}
                """.utf8))
            case ("GET", let tab) where tab.hasPrefix("/api/v1/sessions/"):
                let id = String(tab.dropFirst("/api/v1/sessions/".count))
                if id == homeID { return (200, homePayload()) }
                return (200, Data("""
                {"session":{"id":"\(id)","title":"Tab","workdir":"/tmp","isStreaming":false,"canResume":false,
                "councilMode":false,"queuedCount":0,"status":null,"messages":[],"queued":[]}}
                """.utf8))
            default: return (200, Data(#"{"sessions":[]}"#.utf8))
            }
        }
        addTeardownBlock { @MainActor in
            model.setAppActive(false)
            model.clearConfiguration()
            client.invalidateAndCancel()
            HomeTabsRequestProtocol.handler = nil
        }
        let configured = await model.configure(
            url: "https://cantrip.example", pairingToken: "tabs-token", tailscaleOnly: true
        )
        XCTAssertTrue(configured)
        await model.selectHome()
        model.setAppActive(true)
        await model.refreshNow()
        model.setAppActive(false)
        return model
    }

    private func homePayload() -> Data {
        Data("""
        {"session":{"id":"\(homeID)","title":"Cantrip Home","workdir":"/tmp","isStreaming":false,
        "canResume":false,"councilMode":false,"queuedCount":0,"status":null,"messages":[],"queued":[],
        "isLocked":true,"isCantripHome":true,"supportsBackgroundRuns":true,"backgroundActiveCount":3,
        "buildsRunning":2,"buildsWaiting":1}}
        """.utf8)
    }

    func testListingCarriesTabAgesPreviewsAndHomeSummary() async throws {
        let model = try await configuredModel()
        XCTAssertTrue(model.isHomeSelected)
        XCTAssertEqual(model.sessions.map(\.id), [plexID, bassID])
        let bass = try XCTUnwrap(model.sessions.last)
        XCTAssertEqual(bass.preview, "Resolved: ingestion dry-run incident")
        XCTAssertEqual(CantripRelativeTime.short(try XCTUnwrap(bass.lastActivityDate)), "3h")
        XCTAssertEqual(CantripRelativeTime.short(try XCTUnwrap(model.sessions.first?.lastActivityDate)), "now")
        XCTAssertEqual(model.homeSummary?.isCantripHome, true)
        XCTAssertEqual(model.homeSummary?.pendingInputCount, 1,
                       "Home's listed summary keeps its state current while a tab is open")
        XCTAssertEqual(model.selectedSession?.id, homeID)
    }

    /// The Mac's jobs (build queue and other long work) in the tab lists' Background jobs row and Home's Background list.
    func testBackgroundJobsRowAndListShowTheBuildQueue() async throws {
        let model = try await configuredModel()
        let summary = CantripBackgroundJobsSummary(runs: 3, inputs: 0, home: model.currentHomeSummary)
        XCTAssertEqual(summary.status, "5 running", "Builds count as running jobs")
        XCTAssertEqual(summary.builds, "2 jobs running · 1 waiting")
        XCTAssertEqual(summary.accessibilityValue, "5 running. Jobs on the Mac: 2 running, 1 waiting")
        XCTAssertEqual(CantripBackgroundJobsSummary(buildsRunning: 1).builds, "1 job running")
        XCTAssertTrue(summary.isActive)
        XCTAssertEqual(CantripBackgroundJobsSummary(runs: 0, inputs: 2, buildsRunning: 1).status, "2 need input")
        let waitingOnly = CantripBackgroundJobsSummary(buildsWaiting: 1)
        XCTAssertEqual(waitingOnly.status, "1 waiting")
        XCTAssertEqual(waitingOnly.builds, "1 job waiting")
        XCTAssertEqual(waitingOnly.accessibilityValue, "1 waiting. Jobs on the Mac: 1 waiting")
        XCTAssertTrue(waitingOnly.isActive)
        let idle = CantripBackgroundJobsSummary()
        XCTAssertEqual(idle.status, "None running")
        XCTAssertNil(idle.builds)
        XCTAssertFalse(idle.isActive)
        XCTAssertEqual(CantripDuoSidebarBackground(summary).accessibilityValue, summary.accessibilityValue)

        // Every tab's background tasks count too, with a line of their own above the builds'.
        let withTabs = CantripBackgroundJobsSummary(runs: 3, inputs: 0, home: model.currentHomeSummary, tabs: model.sessions)
        XCTAssertEqual(withTabs.tabTasks, 2)
        XCTAssertEqual(withTabs.status, "7 running")
        XCTAssertEqual(withTabs.details, ["2 in tabs", "2 jobs running · 1 waiting"])
        XCTAssertEqual(withTabs.accessibilityValue, "7 running. Background tasks in tabs: 2. Jobs on the Mac: 2 running, 1 waiting")
        XCTAssertEqual(CantripBackgroundJobsSummary(tabTasks: 1).details, ["1 in a tab"])
        XCTAssertEqual(CantripBackgroundJobsSummary(tabTasks: 1).status, "1 running")
        XCTAssertEqual(CantripDuoSidebarBackground(withTabs).details, withTabs.details)
        let plexible = try XCTUnwrap(model.sessions.first)
        XCTAssertEqual(plexible.backgroundTaskCount, 2)
        XCTAssertTrue(plexible.tabRowAccessibilityValue.contains("2 background tasks running"), plexible.tabRowAccessibilityValue)
        XCTAssertEqual(CantripTabBackgroundNote.accessibilityText(1), "1 background task running")

        // The row opens Home's Background list from a project tab too, so it loads there.
        model.prepareToOpenTab(bassID)
        await model.selectRegularSession()
        XCTAssertFalse(model.isHomeSelected)
        XCTAssertEqual(model.currentHomeSummary?.buildsRunning, 2, "Off Home, the counts come from Home's listed summary")
        await model.refreshHomeBackground()
        let builds = try XCTUnwrap(model.homeBackground?.builds)
        XCTAssertEqual(builds.running.map(\.title), ["xcodebuild archive · App", "swift test · Server", "build-atlas.py"])
        XCTAssertEqual(builds.waiting.map(\.source), ["ci", "tab"])
        XCTAssertEqual(builds.limit, 1)
        let tabTasks = try XCTUnwrap(model.homeBackground?.tabTasks)
        XCTAssertEqual(tabTasks.map(\.tabTitle), ["Docs site"])
        XCTAssertEqual(tabTasks.first?.tasks.map(\.name), ["watch-testflight"])
        XCTAssertEqual(tabTasks.first?.tasks.first?.background, true)

        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(CantripBuildQueueFormat.detail(builds.running[0], place: nil, now: now), "Docs site · 1m 15s")
        XCTAssertEqual(CantripBuildQueueFormat.detail(builds.running[1], place: nil, now: now), "Child tab · Server · 40s")
        XCTAssertEqual(CantripBuildQueueFormat.detail(builds.waiting[0], place: 1, now: now),
                       "Waiting · Next · CI · app · TestFlight · 30s")
        XCTAssertEqual(CantripBuildQueueFormat.detail(builds.waiting[0], place: 2, now: now),
                       "Waiting · 2nd in line · CI · app · TestFlight · 30s")
        // Other long work on the Mac: its state, project, current step and the last line of its log.
        let job = builds.running[2]
        XCTAssertEqual(job.kind, "job")
        XCTAssertEqual(CantripBuildQueueFormat.detail(job, place: nil, now: now),
                       "Waiting on disk · Started outside Cantrip · atlas · "
                       + CantripSubagentFormat.elapsedLabel(startedAt: 992_800, finishedAt: nil, now: now))
        XCTAssertEqual(CantripBuildQueueFormat.extra(job), "Now: compile_shaders.py\nb.log: [5/6] shaders 99%")
        XCTAssertNil(CantripBuildQueueFormat.extra(builds.running[0]))
        XCTAssertEqual(CantripBuildQueueFormat.detail(builds.waiting[1], place: 2, now: now),
                       "Paused · Docs site · " + CantripSubagentFormat.elapsedLabel(startedAt: 996_400, finishedAt: nil, now: now),
                       "A paused job has no place in line")
        XCTAssertEqual(CantripBuildQueueFormat.footnote(.init(enabled: false, slots: 2, limit: 2, running: [], waiting: [])),
                       "Long jobs running on your Mac. The build queue is off, so builds don't take turns.")
        let background = CantripBuildQueueSnapshot.Build(pid: 9, title: "swift build", source: "background", since: 0)
        XCTAssertEqual(CantripBuildQueueFormat.origin(background), "Home background run")
        XCTAssertEqual(CantripBuildQueueFormat.origin(.init(pid: 9, title: "swift build", source: "tab", since: 0)), "A tab")
        XCTAssertEqual([1, 2, 3, 4, 11, 12, 13, 21, 22, 103].map(CantripBuildQueueFormat.ordinal),
                       ["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "103rd"])
        XCTAssertEqual(CantripBuildQueueFormat.footnote(builds),
                       "1 build at a time while macOS reports memory pressure (normally 2). Your tabs go first, then child tabs and CI, then Home's background runs.")
    }

    private func buildQueueBackgroundPayload() -> Data {
        Data("""
        {"sessionID":"\(UUID().uuidString)","revision":"q1","runs":[],"queued":[],"maxParallel":3,"runningCount":0,
         "supportsStop":true,
         "tabTasks":[{"tabID":"\(plexID)","tabTitle":"Docs site","tasks":[{"id":"call_w","agentID":"a1",
           "name":"watch-testflight","agentType":"task","summary":"Wait for TestFlight","background":true,
           "status":"running","startedAt":999900,"canCancel":true}]}],
         "builds":{"enabled":true,"slots":2,"limit":1,"reason":"macOS reports memory pressure",
          "running":[{"pid":101,"title":"xcodebuild archive · App","source":"tab","since":999925,
                      "tabID":"\(plexID)","tabTitle":"Docs site"},
                     {"pid":102,"title":"swift test · Server","source":"child","since":999960,"tabTitle":"Server"},
                     {"pid":104,"title":"build-atlas.py","source":"other","since":992800,"kind":"job","state":"waitingOnDisk",
                      "project":"atlas","step":"compile_shaders.py","logFile":"b.log","logLine":"[5/6] shaders 99%",
                      "logUpdatedAt":999990,"cpu":0.1,"memory":17000000,"processes":6}],
          "waiting":[{"pid":103,"title":"swift build · App","source":"ci","since":999970,"job":"app · TestFlight"},
                     {"pid":105,"title":"export.py","source":"tab","since":996400,"tabTitle":"Docs site","kind":"job","state":"paused"}]}}
        """.utf8)
    }

    func testDrawerCreatesAndOpensTabsWithoutReplacingHome() async throws {
        var creations = 0
        let model = try await configuredModel { creations += 1 }
        let id = await model.createTab()
        XCTAssertEqual(id, newID)
        XCTAssertEqual(creations, 1)
        XCTAssertTrue(model.isHomeSelected, "A tab made from Home's drawer opens as a tab, not in Home's place")
        XCTAssertEqual(model.selectedSession?.id, homeID)
        XCTAssertEqual(model.sessions.last?.id, newID)

        model.prepareToOpenTab(newID)
        await model.selectRegularSession()
        XCTAssertFalse(model.isHomeSelected)
        XCTAssertEqual(model.selectedSessionID, newID)

        await model.selectHome()
        XCTAssertEqual(model.selectedSession?.id, homeID)
        model.prepareToOpenTab(bassID)
        await model.selectRegularSession()
        XCTAssertEqual(model.selectedSessionID, bassID, "Open tab from a handoff card wins over the last tab")
    }

    func testTabActionStateFollowsTheTabAndItsPosition() async throws {
        let model = try await configuredModel()
        let first = CantripTabActionState(session: try XCTUnwrap(model.sessions.first), model: model)
        XCTAssertTrue(first.isFirst)
        XCTAssertFalse(first.isLast)
        XCTAssertTrue(first.isBusy)
        let last = CantripTabActionState(session: try XCTUnwrap(model.sessions.last), model: model)
        XCTAssertTrue(last.isLast)
        XCTAssertFalse(last.isBusy)
        XCTAssertNotEqual(first, last)
    }

    /// Renders the drawer, Home's header button and a tab's header for review. Set
    /// TEST_RUNNER_HOME_TABS_ARTIFACT_DIR (pass TEST_RUNNER_TEST_RUNNER_… to xcodebuild).
    func testHomeTabsScreenshots() async throws {
        let directory = ProcessInfo.processInfo.environment["TEST_RUNNER_HOME_TABS_ARTIFACT_DIR"]
        guard let directory, !directory.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_HOME_TABS_ARTIFACT_DIR to render Home's tabs.")
        }
        let model = try await configuredModel()
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        func capture(_ view: some View, _ name: String, style: UIUserInterfaceStyle, width: CGFloat,
                     height: CGFloat = 760, size: DynamicTypeSize = .large) async throws {
            let controller = UIHostingController(rootView: view.dynamicTypeSize(size))
            controller.overrideUserInterfaceStyle = style
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: CGSize(width: width, height: height))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            try await Task.sleep(for: .milliseconds(400))
            controller.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try XCTUnwrap(image.pngData()).write(to: output.appendingPathComponent("\(name).png"))
        }
        let drawer = CantripHomeTabDrawer(
            model: model, backgroundActiveCount: 3, backgroundInputCount: 0,
            onDismiss: {}, onSelectHome: {}, onOpenBackground: {}, onSelect: { _ in },
            onCreate: {}, onRename: { _ in }, onClose: { _ in }
        )
        .background(.regularMaterial)
        // The unfolded Duo's sidebar: its Background jobs row with the build queue's line.
        let sidebar = CantripDuoSidebar(
            model: model, slashCommands: BackendSlashCommandStore(), isHomeShown: true, homeSection: .chat,
            showsSkills: false, slashToken: nil, highlighted: nil, canOpenModelSettings: false,
            backgroundStatus: .init(CantripBackgroundJobsSummary(runs: 3, inputs: 0, home: model.currentHomeSummary,
                                                                 tabs: model.sessions)),
            isListening: false, isSpeaking: false, onSelectSection: { _ in }, onSelectTab: { _ in },
            onCreateTab: {}, onRename: { _ in }, onClose: { _ in }, onOpenBackground: {},
            onCustomizeMascot: {}, onChoose: { _ in }
        )
        for (name, style) in [("light", UIUserInterfaceStyle.light), ("dark", .dark)] {
            try await capture(sidebar, "home-tabs-duo-sidebar-\(name)", style: style, width: CantripDuoSidebar.width)
            for width: CGFloat in [320, 393] {
                try await capture(drawer.frame(width: CantripDrawerGesture.panelWidth(available: width)),
                                  "home-tabs-drawer-\(name)-\(Int(width))", style: style, width: width)
                try await capture(tabHeader, "home-tabs-tab-header-\(name)-\(Int(width))",
                                  style: style, width: width, height: 140)
            }
        }
        try await capture(drawer, "home-tabs-drawer-ax", style: .dark, width: 393, size: .accessibility3)
        try await capture(sidebar, "home-tabs-duo-sidebar-ax", style: .dark, width: CantripDuoSidebar.width,
                          size: .accessibility3)
        try await capture(tabHeader, "home-tabs-tab-header-ax", style: .dark, width: 393, height: 160,
                          size: .accessibility3)
        try await capture(tabHeader, "home-tabs-tab-header-ax-320", style: .dark, width: 320, height: 160,
                          size: .accessibility3)
    }

    /// The iPhone Duo open upright (669 x 951 pt, an 81 pt status band with the clock and camera ring
    /// at its trailing end): a tab's header below the band (before) and in it (after), beside the
    /// app-drawn rail. Set TEST_RUNNER_HOME_TABS_ARTIFACT_DIR.
    func testDuoUprightTabHeaderScreenshots() async throws {
        XCTAssertEqual(ChatHeaderMetrics.minimumStatusBand, 44)
        let directory = ProcessInfo.processInfo.environment["TEST_RUNNER_HOME_TABS_ARTIFACT_DIR"]
        guard let directory, !directory.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_HOME_TABS_ARTIFACT_DIR to render the upright Duo header.")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let band: CGFloat = 81
        let tab = session(plexID, "Mario Kart World cache-prepared update for first launch stutters", streaming: true,
                          status: "Building the cache")
        func header(inBand: Bool) -> some View {
            ChatHeader(style: .tab, hidesLeadingInRail: true, actionsInRail: true, statusBand: inBand ? band : nil) {
                CantripTabHeaderTitle(session: tab, connectionState: .connected)
            } connection: { EmptyView() } lane: { EmptyView() } usage: { EmptyView() }
            delivery: { EmptyView() } settings: { EmptyView() }
            leading: { EmptyView() } trailing: { ChatMenuIcon(systemName: "ellipsis") }
        }
        func screen(inBand: Bool) -> some View {
            HStack(spacing: 0) {
                VStack(alignment: .trailing, spacing: 12) {
                    Text("Status of the cache build?")
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Color.accentColor, in: Capsule()).foregroundStyle(.white)
                    Text("It's compiling the shaders, about two minutes left.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer()
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground))
                // As ChatView: below the band in its safe-area inset, or over the band.
                .safeAreaInset(edge: .top, spacing: 0) { if !inBand { header(inBand: false) } }
                .overlay(alignment: .top) { if inBand { header(inBand: true).ignoresSafeArea(edges: .top) } }
                CantripDuoAppRail(dividerTop: inBand ? band : 0) {
                    Image(systemName: "sidebar.left").frame(width: 44, height: 44)
                    Image(systemName: "gearshape").frame(width: 44, height: 44)
                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                } bottom: { EmptyView() }
            }
            .overlay(alignment: .topTrailing) {
                // Where the clock and camera ring sit on the device.
                HStack(spacing: 10) {
                    Text("12:28").font(.subheadline.weight(.semibold))
                    Circle().strokeBorder(.secondary, lineWidth: 2).frame(width: 40, height: 40)
                }
                .padding(.trailing, 20).padding(.top, 28)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            }
        }
        for (name, inBand) in [("before", false), ("after", true)] {
            for (styleName, style) in [("dark", UIUserInterfaceStyle.dark), ("light", .light)] {
                let controller = UIHostingController(rootView: screen(inBand: inBand))
                controller.overrideUserInterfaceStyle = style
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(origin: .zero, size: CGSize(width: 669, height: 951))
                window.rootViewController = controller
                window.makeKeyAndVisible()
                defer { window.isHidden = true }
                // Only the measured status band, whatever the screen this test runs on adds.
                let extra = controller.view.safeAreaInsets
                controller.additionalSafeAreaInsets = UIEdgeInsets(top: band - extra.top + controller.additionalSafeAreaInsets.top,
                                                                   left: -extra.left, bottom: -extra.bottom, right: -extra.right)
                try await Task.sleep(for: .milliseconds(400))
                controller.view.layoutIfNeeded()
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                try XCTUnwrap(image.pngData()).write(to: output.appendingPathComponent("duo-upright-tab-\(name)-\(styleName).png"))
            }
        }
    }

    private var tabHeader: some View {
        let plexible = session(plexID, "Plexible", streaming: true)
        return VStack(spacing: 24) {
            ChatHeader(style: .tab) {
                CantripTabHeaderTitle(session: plexible, connectionState: .connected)
            } connection: { EmptyView() } lane: { EmptyView() } usage: { EmptyView() }
            delivery: { EmptyView() } settings: { EmptyView() }
            leading: { CantripHomeBackPill {} }
            trailing: { ChatMenuIcon(systemName: "ellipsis") }
            ChatHeader(style: .mascot) {
                Text("Pip").font(.headline)
            } connection: { EmptyView() } lane: { EmptyView() } usage: { EmptyView() }
            delivery: { EmptyView() } settings: { EmptyView() }
            leading: { CantripHomeTabsButton(workingCount: 2) {} }
            trailing: { ChatMenuIcon() }
            Spacer(minLength: 0)
        }
        .background(Color(.systemBackground))
    }
}
