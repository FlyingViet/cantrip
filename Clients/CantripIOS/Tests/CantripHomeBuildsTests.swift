import SwiftUI
import UIKit
import XCTest
@testable import Hermes

private final class CantripBuildsRequestProtocol: URLProtocol {
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
final class CantripHomeBuildsTests: XCTestCase {
    private let homeID = "7EAE0CE5-8C8B-4652-9FD0-214867A90E5D"
    private let page = "https://mac.example.ts.net:8444"
    /// 1x1 PNG.
    private let iconPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!

    private func client() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CantripBuildsRequestProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func path(_ request: URLRequest) -> String {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
    }

    private func build(
        bundle: String = "com.example.agent", folder: String = "1.0-2-20261015183015", title: String = "Cantrip Agent",
        version: String = "1.0", build: String = "2", hasIcon: Bool = true, published: Date = Date(timeIntervalSince1970: 1_792_200_000),
        note: String? = "Built from main", sizeLabel: String? = "16.9 MB", size: Int64? = 17_700_000,
        profileKind: String? = "Ad Hoc", profileExpires: String? = "Sep 01, 2099"
    ) -> CantripOTABuild {
        let manifest = "\(page)/apps/\(bundle)/\(folder)/manifest.plist"
        let encoded = manifest.addingPercentEncoding(withAllowedCharacters: CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        ))!
        return CantripOTABuild(
            id: "\(bundle)/\(folder)", bundleID: bundle, title: title, version: version, build: build,
            note: note, hasIcon: hasIcon, size: size, sizeLabel: sizeLabel, profileName: "Profile",
            profileKind: profileKind, profileExpires: profileExpires, publishedAt: published,
            publishedLabel: "Oct 15, 6:30 PM", sourceCommit: "abc123", manifestURL: manifest,
            installURL: "itms-services://?action=download-manifest&url=\(encoded)"
        )
    }

    /// The host's JSONEncoder output: dates as seconds since 2001, optional fields omitted when nil.
    private func buildsPayload(revision: String = "r1", apps: Int = 3) -> Data {
        func entry(_ bundle: String, _ folder: String, _ title: String, _ build: String, _ published: Double,
                   icon: Bool = true, extra: String = "") -> String {
            let manifest = "\(page)/apps/\(bundle)/\(folder)/manifest.plist"
            let encoded = manifest.addingPercentEncoding(withAllowedCharacters: CharacterSet(
                charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
            ))!
            return """
            {"id":"\(bundle)/\(folder)","bundleID":"\(bundle)","title":"\(title)","version":"1.0","build":"\(build)",
            "hasIcon":\(icon),"publishedAt":\(published),"manifestURL":"\(manifest)",
            "installURL":"itms-services://?action=download-manifest&url=\(encoded)"\(extra)}
            """
        }
        let all = [
            """
            {"id":"com.example.agent","title":"Cantrip Agent","bundleID":"com.example.agent","builds":[
            \(entry("com.example.agent", "1.0-100135-20261016090000", "Cantrip Agent", "100135", 813_859_200,
                    extra: #","note":"Builds tab","size":17700000,"sizeLabel":"16.9 MB","profileKind":"Ad Hoc","profileExpires":"Sep 01, 2099""#)),
            \(entry("com.example.agent", "1.0-100134-20261015183015", "Cantrip Agent", "100134", 813_800_000,
                    extra: #","sizeLabel":"16.8 MB","profileKind":"Ad Hoc""#))]}
            """,
            """
            {"id":"brane","title":"Brane Controller","bundleID":"com.example.shared","builds":[
            \(entry("com.example.shared", "1.0-1-20261015183301", "Brane Controller", "1", 813_700_000,
                    extra: #","profileKind":"Development","profileExpires":"Jan 01, 2020""#))]}
            """,
            """
            {"id":"crooner","title":"Crooner","bundleID":"com.example.shared","builds":[
            \(entry("com.example.shared", "1.0-1-20261015183300", "Crooner", "1", 813_600_000, icon: false))]}
            """,
        ]
        return Data("""
        {"apps":[\(all.prefix(apps).joined(separator: ","))],"pageURL":"\(page)/","available":true,
        "skipped":1,"revision":"\(revision)"}
        """.utf8)
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

    private func configuredModel(
        builds: @escaping (URLRequest) async throws -> (Int, Data)
    ) async throws -> (CantripRemoteModel, URLSession) {
        let client = client()
        let model = CantripRemoteModel(urlSession: client)
        CantripBuildsRequestProtocol.handler = { request in
            switch self.path(request) {
            case "/api/v1/home": return (200, self.homeSessionPayload())
            case "/api/v1/home/tasks": return (200, Data(#"{"tasks":[],"revision":"t"}"#.utf8))
            case "/api/v1/home/artifacts": return (200, Data(#"{"artifacts":[],"revision":"a"}"#.utf8))
            case let path where path.hasPrefix("/api/v1/home/builds"): return try await builds(request)
            default: return (200, Data(#"{"sessions":[]}"#.utf8))
            }
        }
        addTeardownBlock { @MainActor in
            model.clearConfiguration()
            client.invalidateAndCancel()
            CantripBuildsRequestProtocol.handler = nil
        }
        let configured = await model.configure(
            url: "https://cantrip.example", pairingToken: "builds-token", tailscaleOnly: true
        )
        XCTAssertTrue(configured)
        await model.selectHome()
        XCTAssertTrue(model.isHomeSelected)
        return (model, client)
    }

    func testBuildsTabFollowsArtifacts() {
        XCTAssertEqual(CantripHomeSection.allCases.suffix(2), [.artifacts, .builds])
        XCTAssertEqual(CantripHomeSection.builds.title, "Builds")
        XCTAssertEqual(CantripHomeSection.builds.systemImage, "arrow.down.app")
    }

    func testSnapshotDecodesHostJSON() throws {
        let snapshot = try JSONDecoder().decode(CantripOTABuildsSnapshot.self, from: buildsPayload())
        XCTAssertEqual(snapshot.apps.map(\.id), ["com.example.agent", "brane", "crooner"])
        XCTAssertEqual(snapshot.pageURL, "\(page)/")
        XCTAssertEqual(snapshot.skipped, 1)
        let newest = try XCTUnwrap(snapshot.apps.first?.builds.first)
        XCTAssertEqual(newest.build, "100135")
        XCTAssertEqual(newest.note, "Builds tab")
        XCTAssertEqual(newest.size, 17_700_000)
        XCTAssertEqual(newest.publishedAt, Date(timeIntervalSinceReferenceDate: 813_859_200))
        let bare = try XCTUnwrap(snapshot.apps.last?.builds.first)
        XCTAssertNil(bare.note)
        XCTAssertNil(bare.sizeLabel)
        XCTAssertNil(bare.profileKind)
        XCTAssertFalse(bare.hasIcon)
    }

    func testRefreshLoadsBuildsKeepsThemOnErrorsAndClearsOnReset() async throws {
        var response: () throws -> (Int, Data) = { (200, self.buildsPayload()) }
        var requests: [String] = []
        let (model, _) = try await configuredModel { request in
            requests.append("\(request.httpMethod ?? "GET") \(self.path(request))")
            return try response()
        }
        XCTAssertNil(model.homeBuilds)
        await model.refreshHomeBuilds()
        XCTAssertEqual(model.homeBuilds?.apps.count, 3)
        XCTAssertNil(model.homeBuildsError)
        XCTAssertEqual(requests, ["GET /api/v1/home/builds"])

        response = { (404, Data(#"{"error":"not found"}"#.utf8)) }
        await model.refreshHomeBuilds()
        XCTAssertEqual(model.homeBuildsError, "Update Cantrip on the Mac to list its install builds.")
        XCTAssertEqual(model.homeBuilds?.apps.count, 3, "A failed refresh keeps the last list")

        response = { throw URLError(.cannotFindHost) }
        await model.refreshHomeBuilds()
        XCTAssertEqual(model.homeBuildsError?.hasPrefix("Can't reach Cantrip on your Mac."), true,
                       model.homeBuildsError ?? "nil")

        response = { (200, self.buildsPayload(revision: "r2", apps: 1)) }
        await model.refreshHomeBuilds()
        XCTAssertNil(model.homeBuildsError)
        XCTAssertEqual(model.homeBuilds?.revision, "r2")
        XCTAssertTrue(requests.allSatisfy { $0.hasPrefix("GET ") }, "Builds are read-only: \(requests)")

        model.clearConfiguration()
        XCTAssertNil(model.homeBuilds)
        XCTAssertNil(model.homeBuildsError)
    }

    func testIconsUseTheBuildPathAndCacheInMemoryAndOnDisk() async throws {
        var iconRequests: [String] = []
        let (model, _) = try await configuredModel { request in
            let path = self.path(request)
            guard path.hasSuffix("/icon") else { return (200, self.buildsPayload()) }
            iconRequests.append(path)
            if path.contains("missing") { return (404, Data(#"{"error":"This build has no icon."}"#.utf8)) }
            return (200, Data(#"{"data":"\#(self.iconPNG.base64EncodedString())","mimeType":"image/png"}"#.utf8))
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ota-icons-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let cache = CantripOTAIconCache(directory: directory)
        let item = build()
        XCTAssertNil(cache.cached(item))
        let image = await cache.image(for: item, remote: model)
        XCTAssertEqual(image?.size, CGSize(width: 1, height: 1))
        XCTAssertEqual(iconRequests, ["/api/v1/home/builds/com.example.agent/1.0-2-20261015183015/icon"])
        _ = await cache.image(for: item, remote: model)
        XCTAssertEqual(iconRequests.count, 1, "Icons are fetched once")
        XCTAssertNotNil(CantripOTAIconCache(directory: directory).cached(item), "Icons survive relaunch in Caches")

        let noIcon = await cache.image(for: build(folder: "1.0-3-20261016000000", hasIcon: false), remote: model)
        XCTAssertNil(noIcon)
        XCTAssertEqual(iconRequests.count, 1, "Builds without icons make no request")
        let firstMissing = await cache.image(for: build(folder: "missing"), remote: model)
        XCTAssertNil(firstMissing)
        let missing = await cache.image(for: build(folder: "missing"), remote: model)
        XCTAssertNil(missing)
        XCTAssertEqual(iconRequests.count, 3, "A missing icon isn't cached as a failure")
        let invalid = CantripOTABuild(
            id: "com.example.agent/..", bundleID: "com.example.agent", title: "x", version: "1", build: "1",
            note: nil, hasIcon: true, size: nil, sizeLabel: nil, profileName: nil, profileKind: nil,
            profileExpires: nil, publishedAt: Date(), publishedLabel: nil, sourceCommit: nil,
            manifestURL: "", installURL: ""
        )
        let traversal = await cache.image(for: invalid, remote: model)
        XCTAssertNil(traversal)
        XCTAssertEqual(iconRequests.count, 3, "Traversal ids never reach the Mac")
    }

    func testInstallLinksMustNameTheirHTTPSManifest() throws {
        let item = build()
        let links = try XCTUnwrap(CantripOTAInstaller.links(for: item))
        XCTAssertEqual(links.install.absoluteString, item.installURL)
        XCTAssertEqual(links.manifest.absoluteString, item.manifestURL)
        func variant(manifest: String? = nil, install: String? = nil) -> CantripOTABuild {
            CantripOTABuild(
                id: item.id, bundleID: item.bundleID, title: item.title, version: item.version, build: item.build,
                note: nil, hasIcon: false, size: nil, sizeLabel: nil, profileName: nil, profileKind: nil,
                profileExpires: nil, publishedAt: item.publishedAt, publishedLabel: nil, sourceCommit: nil,
                manifestURL: manifest ?? item.manifestURL, installURL: install ?? item.installURL
            )
        }
        XCTAssertNil(CantripOTAInstaller.links(for: variant(manifest: "\(page)/apps/other/manifest.plist")))
        XCTAssertNil(CantripOTAInstaller.links(for: variant(
            manifest: "http://mac.example/m.plist",
            install: "itms-services://?action=download-manifest&url=http%3A%2F%2Fmac.example%2Fm.plist"
        )))
        XCTAssertNil(CantripOTAInstaller.links(for: variant(install: "https://mac.example/install")))
        XCTAssertNil(CantripOTAInstaller.links(for: variant(
            install: item.installURL.replacingOccurrences(of: "download-manifest", with: "other")
        )))
    }

    func testInstallCheckDistinguishesReachableMissingAndUnreachable() async throws {
        let session = client()
        addTeardownBlock { @MainActor in
            session.invalidateAndCancel()
            CantripBuildsRequestProtocol.handler = nil
        }
        let manifest = try XCTUnwrap(URL(string: build().manifestURL))
        var methods: [String] = []
        var result: () throws -> Int = { 200 }
        CantripBuildsRequestProtocol.handler = { request in
            methods.append(request.httpMethod ?? "")
            return (try result(), Data())
        }
        let reachable = await CantripOTAInstaller.check(manifest, session: session)
        XCTAssertEqual(reachable, .reachable)
        result = { 404 }
        let missing = await CantripOTAInstaller.check(manifest, session: session)
        XCTAssertEqual(missing, .missing)
        result = { 502 }
        let badGateway = await CantripOTAInstaller.check(manifest, session: session)
        XCTAssertEqual(badGateway, .unreachable)
        result = { throw URLError(.cannotFindHost) }
        let offline = await CantripOTAInstaller.check(manifest, session: session)
        XCTAssertEqual(offline, .unreachable)
        XCTAssertEqual(methods, ["HEAD", "HEAD", "HEAD", "HEAD"], "The check only probes; it downloads nothing")
    }

    func testInstallProblemsExplainWhatToDo() {
        let item = build()
        let unreachable = CantripOTAInstallProblem(kind: .unreachable, build: item)
        XCTAssertEqual(unreachable.title, "Can't reach the install page")
        XCTAssertTrue(unreachable.message.contains("Turn on Tailscale"))
        XCTAssertTrue(CantripOTAInstallProblem(kind: .missing, build: item).message.contains("1.0 (2)"))
        XCTAssertTrue(CantripOTAInstallProblem(kind: .cannotOpen, build: item).message.contains("Safari"))
    }

    func testPresentationSummarizesEachBuild() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        calendar.locale = Locale(identifier: "en_US")
        let published = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-16T01:30:00Z"))
        let item = build(published: published)
        XCTAssertEqual(CantripHomeBuildsPresentation.versionText(item), "1.0 (2)")
        let sameYear = CantripHomeBuildsPresentation.publishedText(published, now: published, calendar: calendar)
        XCTAssertTrue(sameYear.contains("Oct 15") && !sameYear.contains("2026"), sameYear)
        let lastYear = CantripHomeBuildsPresentation.publishedText(
            published, now: published.addingTimeInterval(400 * 86_400), calendar: calendar
        )
        XCTAssertTrue(lastYear.contains("2026"), lastYear)
        XCTAssertTrue(CantripHomeBuildsPresentation.detailText(item).hasSuffix(" · 16.9 MB · Ad Hoc"))
        XCTAssertEqual(CantripHomeBuildsPresentation.sizeText(build(sizeLabel: nil, size: 2_000_000)),
                       ByteCountFormatter.string(fromByteCount: 2_000_000, countStyle: .file))
        XCTAssertNil(CantripHomeBuildsPresentation.sizeText(build(sizeLabel: nil, size: nil)))
        let spoken = CantripHomeBuildsPresentation.accessibilityText("Cantrip Agent", item)
        XCTAssertTrue(spoken.hasPrefix("Cantrip Agent, version 1.0, build 2, published "), spoken)
        XCTAssertTrue(spoken.hasSuffix(", 16.9 MB, Ad Hoc profile"), spoken)

        XCTAssertEqual(CantripHomeBuildsPresentation.profileExpiry("Sep 01, 2027"),
                       ISO8601DateFormatter().date(from: "2027-09-01T00:00:00Z"))
        XCTAssertTrue(CantripHomeBuildsPresentation.notices(item, sharesBundleWith: []).isEmpty)
        let expired = CantripHomeBuildsPresentation.notices(build(profileExpires: "Jan 01, 2020"), sharesBundleWith: [])
        XCTAssertEqual(expired.count, 1)
        XCTAssertTrue(expired[0].text.contains("expired Jan 01, 2020"))
        let shared = CantripHomeBuildsPresentation.notices(item, sharesBundleWith: ["Crooner"])
        XCTAssertEqual(shared.map(\.text), ["Installing replaces Crooner (same bundle ID)."])

        let snapshot = try JSONDecoder().decode(CantripOTABuildsSnapshot.self, from: buildsPayload())
        XCTAssertEqual(CantripHomeBuildsPresentation.sharedBundleTitles(snapshot.apps),
                       ["brane": ["Crooner"], "crooner": ["Brane Controller"]])
        XCTAssertTrue(CantripHomeBuildsPresentation.isRunningApp(build(bundle: Bundle.main.bundleIdentifier!)))
        XCTAssertFalse(CantripHomeBuildsPresentation.isRunningApp(item))
    }

    func testCompactBarFitsFourTabsAtEverySize() async throws {
        for (width, size) in [(369.0, DynamicTypeSize.large), (369, .xxxLarge), (296, .accessibility5), (320, .large)] {
            let controller = UIHostingController(rootView:
                CantripHomeCompactTabBar(selection: .constant(.builds), runningTasks: 3)
                    .environment(\.dynamicTypeSize, size)
            )
            XCTAssertEqual(controller.sizeThatFits(in: CGSize(width: width, height: 100)).height, 48, accuracy: 1,
                           "\(size) at \(width)")
        }
    }

    func testEqualWidthRowIdealFitsTheWidestChildInEverySlot() {
        let row = CantripHomeEqualWidthRow(spacing: 2) {
            Color.clear.frame(idealWidth: 30, idealHeight: 20)
            Color.clear.frame(idealWidth: 80, idealHeight: 44)
            Color.clear.frame(idealWidth: 50, idealHeight: 10)
        }
        let ideal = UIHostingController(rootView: row.fixedSize()).sizeThatFits(in: CGSize(width: 1_000, height: 1_000))
        XCTAssertEqual(ideal.width, 80 * 3 + 4, accuracy: 0.5)
        XCTAssertEqual(ideal.height, 44, accuracy: 0.5)
        let chosen = UIHostingController(rootView:
            ViewThatFits(in: .horizontal) {
                row
                Color.red.frame(width: 10, height: 10)
            }
        ).sizeThatFits(in: CGSize(width: 200, height: 100))
        XCTAssertEqual(chosen.width, 10, accuracy: 0.5, "A row whose widest slot can't fit falls back")
    }

    /// Light/dark, large-text, error and empty renders for review.
    func testBuildsTabScreenshots() async throws {
        let directory = ProcessInfo.processInfo.environment["TEST_RUNNER_HOME_BUILDS_ARTIFACT_DIR"]
        guard let directory, !directory.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_HOME_BUILDS_ARTIFACT_DIR to render the Builds tab.")
        }
        var payload: () throws -> (Int, Data) = { (200, self.buildsPayload()) }
        let (model, _) = try await configuredModel { request in
            if self.path(request).hasSuffix("/icon") {
                return (200, Data(#"{"data":"\#(self.iconPNG.base64EncodedString())","mimeType":"image/png"}"#.utf8))
            }
            return try payload()
        }
        await model.refreshHomeBuilds()
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        func capture(_ name: String, style: UIUserInterfaceStyle, size: DynamicTypeSize = .large,
                     width: CGFloat = 393) async throws {
            let controller = UIHostingController(rootView:
                CantripHomeTabs(selection: .constant(.builds), runningTasks: 1) {
                    Color.clear
                } tasks: {
                    Color.clear
                } artifacts: {
                    Color.clear
                } builds: {
                    NavigationStack { CantripHomeBuildsView(remote: model) }
                }
                .dynamicTypeSize(size)
            )
            controller.overrideUserInterfaceStyle = style
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: CGSize(width: width, height: 852))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            try await Task.sleep(for: .milliseconds(600))
            controller.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try XCTUnwrap(image.pngData()).write(to: output.appendingPathComponent("\(name).png"))
        }
        try await capture("builds-light", style: .light)
        try await capture("builds-dark", style: .dark)
        try await capture("builds-ax3", style: .light, size: .accessibility3)
        try await capture("builds-xxxl-320", style: .dark, size: .xxxLarge, width: 320)
        payload = { throw URLError(.cannotFindHost) }
        await model.refreshHomeBuilds()
        try await capture("builds-stale-error", style: .light)
        model.clearConfiguration()
        let (fresh, _) = try await configuredModel { _ in throw URLError(.timedOut) }
        await fresh.refreshHomeBuilds()
        let controller = UIHostingController(rootView: NavigationStack { CantripHomeBuildsView(remote: fresh) })
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: CGSize(width: 393, height: 852))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(500))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try XCTUnwrap(image.pngData()).write(to: output.appendingPathComponent("builds-error.png"))
    }
}
