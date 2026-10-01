import SwiftUI
import UIKit
import XCTest
@testable import Hermes

private final class MascotRequestProtocol: URLProtocol {
    @MainActor static var handler: ((URLRequest) -> Data)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Task { @MainActor in
            let data = Self.handler?(request) ?? Data(#"{"sessions":[]}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

@MainActor
final class CantripMascotTests: XCTestCase {
    func testMoodPrioritizesDisconnectedThenUserNeeds() {
        func mood(
            connected: Bool = true, working: Bool = false, listening: Bool = false,
            speaking: Bool = false, input: Bool = false
        ) -> CantripMascotMood {
            .resolve(isConnected: connected, isWorking: working, isListening: listening,
                     isSpeaking: speaking, needsInput: input)
        }
        XCTAssertEqual(mood(), .idle)
        XCTAssertEqual(mood(working: true), .thinking)
        XCTAssertEqual(mood(working: true, speaking: true), .speaking)
        XCTAssertEqual(mood(working: true, listening: true, speaking: true), .listening)
        XCTAssertEqual(mood(working: true, listening: true, input: true), .curious)
        XCTAssertEqual(mood(connected: false, working: true, input: true), .sleeping)
        XCTAssertEqual(CantripMascotMood.thinking.accessibilityStatus, "Working")
        XCTAssertNil(CantripMascotMood.idle.accessibilityStatus)
    }

    func testBlinkIsBriefAndStaticPoseHasOpenEyes() {
        XCTAssertEqual(CantripMascotRenderer.openness(1), 1)
        XCTAssertLessThan(CantripMascotRenderer.openness(4.3 - 1.1 + 0.08), 0.1)
        let samples = stride(from: 0.0, to: 43.0, by: 0.01).map(CantripMascotRenderer.openness)
        let closedShare = Double(samples.filter { $0 < 1 }.count) / Double(samples.count)
        XCTAssertLessThan(closedShare, 0.06, "Eyes should be open nearly all the time")
    }

    func testMascotHeaderCentersAvatarWithAlignedGlassActions() throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        for width in [320.0, 393.0, 440.0] {
            for size in [DynamicTypeSize.large, .accessibility5] {
                var titleFrame = CGRect.zero
                var leadingFrame = CGRect.zero
                var trailingFrame = CGRect.zero
                var headerFrame = CGRect.zero
                var contentFrame = CGRect.zero
                let content = VStack {
                    Text("Transcript").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    contentFrame = $0
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    ChatHeader(compact: true, mascot: true) {
                        CantripMascotHeaderTitle(title: "Cantrip Home", isConnected: true, mood: .idle)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                                titleFrame = $0
                            }
                    } connection: {
                        EmptyView()
                    } lane: {
                        EmptyView()
                    } usage: {
                        EmptyView()
                    } delivery: {
                        EmptyView()
                    } refresh: {
                        EmptyView()
                    } settings: {
                        EmptyView()
                    } leading: {
                        ExecutionLaneBadge(lane: .home, iconOnly: true)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                                leadingFrame = $0
                            }
                    } trailing: {
                        Button {} label: { ChatMenuIcon() }
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                                trailingFrame = $0
                            }
                    }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                        headerFrame = $0
                    }
                }
                .environment(\.dynamicTypeSize, size)
                let controller = UIHostingController(rootView: content)
                // Widths are safe content widths; Duo's native rail would otherwise narrow them.
                controller.safeAreaRegions = []
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: width, height: 700)
                window.rootViewController = controller
                window.makeKeyAndVisible()
                defer { window.isHidden = true }
                controller.view.layoutIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

                let label = "\(Int(width))pt \(size)"
                let avatar = CantripMascotHeaderTitle.avatarSize
                XCTAssertEqual(titleFrame.midX, width / 2, accuracy: 1, label)
                XCTAssertGreaterThan(titleFrame.height, avatar, label)
                XCTAssertLessThanOrEqual(titleFrame.maxY, headerFrame.maxY, label)
                XCTAssertGreaterThanOrEqual(titleFrame.minY, headerFrame.minY, label)
                XCTAssertLessThanOrEqual(headerFrame.height, avatar + 34, "\(label): header stays compact")
                XCTAssertEqual(leadingFrame.size, CGSize(width: 44, height: 44), label)
                XCTAssertEqual(trailingFrame.width, 44, accuracy: 0.5, label)
                XCTAssertEqual(trailingFrame.height, 44, accuracy: 0.5, label)
                XCTAssertEqual(leadingFrame.minX, 12, accuracy: 1, label)
                XCTAssertEqual(trailingFrame.maxX, width - 12, accuracy: 1, label)
                XCTAssertEqual(leadingFrame.midY, titleFrame.minY + avatar / 2, accuracy: 1,
                               "\(label): actions align with the avatar center")
                XCTAssertEqual(trailingFrame.midY, leadingFrame.midY, accuracy: 0.5, label)
                XCTAssertLessThanOrEqual(leadingFrame.maxX, titleFrame.minX, label)
                XCTAssertGreaterThanOrEqual(trailingFrame.minX, titleFrame.maxX, label)
                XCTAssertEqual(contentFrame.minY, headerFrame.maxY, accuracy: 1,
                               "\(label): the first message starts below the mascot")
            }
        }
    }

    func testMascotHeaderOnVerticalBarKeepsOnlyTheCenteredMascot() throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        var titleFrame = CGRect.zero
        var leadingFrame = CGRect.zero
        var headerFrame = CGRect.zero
        let content = Color.clear
            .safeAreaInset(edge: .top, spacing: 0) {
                ChatHeader(compact: true, mascot: true) {
                    CantripMascotHeaderTitle(title: "Cantrip Home", isConnected: true, mood: .thinking)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                            titleFrame = $0
                        }
                } connection: {
                    EmptyView()
                } lane: {
                    EmptyView()
                } usage: {
                    EmptyView()
                } delivery: {
                    EmptyView()
                } refresh: {
                    EmptyView()
                } settings: {
                    EmptyView()
                } leading: {
                    Color.red.onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                        leadingFrame = $0
                    }
                } trailing: {
                    EmptyView()
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                    headerFrame = $0
                }
            }
            .environment(\.chatDisplayTraits, ChatDisplayTraits(hasVerticalBar: true))
        let controller = UIHostingController(rootView: content)
        controller.safeAreaRegions = []
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 700)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        XCTAssertTrue(leadingFrame == .zero || !headerFrame.intersects(leadingFrame),
                      "Side actions move to the system vertical bar")
        XCTAssertEqual(titleFrame.midX, 393 / 2, accuracy: 1)
        XCTAssertGreaterThanOrEqual(titleFrame.minY, headerFrame.minY)
        XCTAssertLessThanOrEqual(titleFrame.maxY, headerFrame.maxY)
    }

    func testEveryMoodRendersADistinctFrame() throws {
        var images: [CantripMascotMood: Data] = [:]
        for mood in CantripMascotMood.allCases {
            let renderer = ImageRenderer(content:
                CantripMascotView(mood: mood, size: 120, frameTime: 1)
                    .padding(12)
            )
            renderer.scale = 2
            let data = try XCTUnwrap(renderer.uiImage?.pngData(), "\(mood)")
            images[mood] = data
        }
        XCTAssertEqual(Set(images.values).count, CantripMascotMood.allCases.count,
                       "Each mood should look different")
        let celebration = ImageRenderer(content:
            CantripMascotView(mood: .idle, size: 120, frameTime: 1, celebrationProgress: 0.3)
                .padding(12)
        )
        celebration.scale = 2
        XCTAssertNotEqual(celebration.uiImage?.pngData(), images[.idle])
    }

    func testRealHomeChatRestsTranscriptBelowMascot() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MascotRequestProtocol.self]
        let client = URLSession(configuration: configuration)
        let model = CantripRemoteModel(urlSession: client)
        let reply = """
        Here are three listings worth a look:\\n\\n\
        - **238 E 106th St #3D, East Harlem** — $3,000, just cut from $3,100 today, 1ba, central air, \
        6 min to 103rd St. Available now.\\n\
        - **41-21 28th St #9F, LIC (The Delmar)** — $3,250, doorman, gym, roof deck.\\n\
        - **155 W 21st St #4B, Chelsea** — $3,400, renovated kitchen, in-unit laundry.
        """
        MascotRequestProtocol.handler = { request in
            switch request.url?.path ?? "" {
            case "/api/v1/home":
                return Data("""
                {"session":{"id":"7EAE0CE5-8C8B-4652-9FD0-214867A90E5D","title":"Cantrip Home",
                "workdir":"/tmp","isStreaming":false,"canResume":false,"councilMode":false,
                "queuedCount":0,"status":null,"queued":[],"supportsAutoDelivery":true,
                "isLocked":true,"isCantripHome":true,"supportsModelSettings":true,
                "messages":[{"id":"ask","role":"user","text":"Any new apartments under $3.5k?",
                "thinking":"","activities":[]},{"id":"reply","role":"assistant","text":"\(reply)",
                "thinking":"","activities":[]}]}}
                """.utf8)
            case "/api/v1/home/tasks": return Data(#"{"tasks":[],"revision":"r"}"#.utf8)
            case "/api/v1/home/artifacts": return Data(#"{"artifacts":[],"revision":"r"}"#.utf8)
            case "/api/v1/copilot/usage": return Data(#"{"isRefreshing":false}"#.utf8)
            default: return Data(#"{"sessions":[]}"#.utf8)
            }
        }
        let env = HermesEnv()
        let originalLane = env.executionLane
        addTeardownBlock { @MainActor in
            env.select(originalLane)
            model.clearConfiguration()
            client.invalidateAndCancel()
            MascotRequestProtocol.handler = nil
        }
        let configured = await model.configure(
            url: "https://cantrip.example", pairingToken: "mascot-token", tailscaleOnly: true
        )
        XCTAssertTrue(configured)
        env.select(.home)
        await model.selectHome()
        XCTAssertEqual(model.selectedSession?.isCantripHome, true)

        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let controller = UIHostingController(rootView: ChatView(env: env, remote: model))
        controller.overrideUserInterfaceStyle = .dark
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: CGSize(width: 393, height: 852))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(400))
        controller.view.layoutIfNeeded()

        func scrollViews(in view: UIView) -> [UIScrollView] {
            ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
        }
        let transcript = try XCTUnwrap(
            scrollViews(in: controller.view)
                .filter { $0.bounds.height > 300 && $0.contentSize.height > 0 }
                .max { $0.bounds.height < $1.bounds.height },
            "The Home transcript scroll view should exist"
        )
        XCTAssertGreaterThanOrEqual(
            transcript.adjustedContentInset.top,
            controller.view.safeAreaInsets.top + CantripMascotHeaderTitle.avatarSize + 10,
            "The first message must rest below the mascot"
        )
        let directory = ProcessInfo.processInfo.environment["TEST_RUNNER_HOME_ARTIFACT_DIR"]
        guard let directory, !directory.isEmpty else { return }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try XCTUnwrap(image.pngData()).write(
            to: URL(fileURLWithPath: directory).appendingPathComponent("cantrip-mascot-home-chat.png")
        )
    }

    func testMascotArtifacts() async throws {
        let directory = ProcessInfo.processInfo.environment["TEST_RUNNER_HOME_ARTIFACT_DIR"]
        guard let directory, !directory.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_HOME_ARTIFACT_DIR to render the mascot.")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        for (name, style) in [("light", UIUserInterfaceStyle.light), ("dark", .dark)] {
            let sheet = UIHostingController(rootView:
                VStack(spacing: 18) {
                    ForEach([[CantripMascotMood.idle, .thinking, .listening],
                             [.speaking, .curious, .sleeping]], id: \.self) { row in
                        HStack(spacing: 18) {
                            ForEach(row, id: \.self) { mood in
                                VStack(spacing: 6) {
                                    CantripMascotView(mood: mood, size: 112, frameTime: 1)
                                    Text(String(describing: mood)).font(.caption)
                                }
                            }
                        }
                    }
                    HStack(spacing: 18) {
                        CantripMascotView(mood: .idle, size: 112, frameTime: 1, celebrationProgress: 0.3)
                        CantripMascotHeaderTitle(title: "Cantrip Home", isConnected: true, mood: .idle)
                    }
                }
                .padding(24)
                .frame(width: 440, height: 560)
                .background(Color(.systemBackground))
            )
            sheet.overrideUserInterfaceStyle = style
            try await capture(sheet, size: CGSize(width: 440, height: 560), scene: scene,
                              to: output.appendingPathComponent("cantrip-mascot-moods-\(name).png"))

            let transcript = """
            • 238 E 106th St #3D, East Harlem — $3,000, just cut from $3,100 today, 1ba, central air, \
            6 min to 103rd St. Available now. Worth a look given why it's been sitting.

            • 41-21 28th St #9F, LIC (The Delmar) — $3,250, doorman, gym, roof deck. Lease starts Nov 1.

            • 155 W 21st St #4B, Chelsea — $3,400, renovated kitchen, in-unit laundry.
            """
            let header = UIHostingController(rootView:
                ScrollView {
                    Text(transcript)
                        .font(.body)
                        .padding(.horizontal, 20)
                        .padding(.top, -28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollDisabled(true)
                .safeAreaInset(edge: .top, spacing: 0) {
                    ChatHeader(compact: true, mascot: true) {
                        CantripMascotHeaderTitle(title: "Cantrip Home", isConnected: true, mood: .idle)
                    } connection: {
                        EmptyView()
                    } lane: {
                        EmptyView()
                    } usage: {
                        EmptyView()
                    } delivery: {
                        EmptyView()
                    } refresh: {
                        EmptyView()
                    } settings: {
                        EmptyView()
                    } leading: {
                        ExecutionLaneBadge(lane: .home, iconOnly: true)
                    } trailing: {
                        Button {} label: { ChatMenuIcon() }
                    }
                }
                .background(Color(.systemBackground))
            )
            header.overrideUserInterfaceStyle = style
            try await capture(header, size: CGSize(width: 393, height: 340), scene: scene,
                              to: output.appendingPathComponent("cantrip-mascot-header-\(name).png"))
        }
    }

    private func capture(
        _ controller: UIViewController, size: CGSize, scene: UIWindowScene, to url: URL
    ) async throws {
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(300))
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try XCTUnwrap(image.pngData()).write(to: url)
    }
}
