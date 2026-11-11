import Foundation
import XCTest
@testable import Hermes

private final class TabSwitchRequestProtocol: URLProtocol {
    @MainActor static var handler: ((URLRequest) async throws -> (Int, Data))?
    private var responseTask: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { responseTask?.cancel() }
    override func startLoading() {
        responseTask = Task { @MainActor in
            do {
                let handler = try XCTUnwrap(Self.handler)
                let (status, data) = try await handler(request)
                try Task.checkCancellation()
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

/// A switch to a tab or to Home shows it in the caller's update (its last copy, when one is
/// cached), then loads it: the Mac's sidebar highlight and the conversation change together
/// instead of bouncing back to the previous row for a beat.
@MainActor
final class CantripTabSwitchTests: XCTestCase {
    private let homeID = "00000000-0000-0000-0000-0000000000a0"
    private let tabA = "00000000-0000-0000-0000-0000000000a1"
    private let tabB = "00000000-0000-0000-0000-0000000000a2"
    private let tabC = "00000000-0000-0000-0000-0000000000a3"
    private var reads: [String: Int] = [:]

    private func session(_ id: String, title: String, home: Bool = false) -> String {
        """
        {"id":"\(id)","title":"\(title)","workdir":"/tmp","isStreaming":false,"canResume":false,
         "councilMode":false,"queuedCount":0\(home ? #","isCantripHome":true"# : "")}
        """
    }

    private func detail(_ id: String, title: String, home: Bool = false) -> Data {
        Data("""
        {"session":{"id":"\(id)","title":"\(title)","workdir":"/tmp","isStreaming":false,"canResume":false,
         "councilMode":false,"queuedCount":0,"status":null,"queued":[]\(home ? #","isCantripHome":true"# : ""),
         "messages":[{"id":"\(id)-1","role":"user","text":"Example question in \(title)","thinking":"","activities":[]},
                     {"id":"\(id)-2","role":"assistant","text":"Example answer in \(title)","thinking":"","activities":[]}]}}
        """.utf8)
    }

    private func model() async throws -> CantripRemoteModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TabSwitchRequestProtocol.self]
        let client = URLSession(configuration: configuration)
        let model = CantripRemoteModel(urlSession: client)
        let titles = [tabA: "Example A", tabB: "Example B", tabC: "Example C"]
        TabSwitchRequestProtocol.handler = { [self] request in
            let path = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
            switch (request.httpMethod ?? "GET", path) {
            case ("GET", "/api/v1/home"):
                reads[homeID, default: 0] += 1
                return (200, detail(homeID, title: "Cantrip Home", home: true))
            case (_, "/api/v1/home/tasks"): return (200, Data(#"{"tasks":[]}"#.utf8))
            case (_, "/api/v1/home/artifacts"): return (200, Data(#"{"artifacts":[]}"#.utf8))
            case ("GET", "/api/v1/sessions"):
                let tabs = [tabA, tabB, tabC].map { session($0, title: titles[$0]!) }.joined(separator: ",")
                return (200, Data(#"{"sessions":[\#(tabs)],"home":\#(session(homeID, title: "Cantrip Home", home: true))}"#.utf8))
            case ("GET", let tab) where tab.hasPrefix("/api/v1/sessions/"):
                let id = String(tab.dropFirst("/api/v1/sessions/".count))
                reads[id, default: 0] += 1
                return (200, detail(id, title: titles[id] ?? "Cantrip Home", home: id == homeID))
            default: return (200, Data(#"{"sessions":[]}"#.utf8))
            }
        }
        addTeardownBlock { @MainActor in
            model.setAppActive(false)
            model.clearConfiguration()
            client.invalidateAndCancel()
            TabSwitchRequestProtocol.handler = nil
        }
        let configured = await model.configure(url: "https://cantrip.example", pairingToken: "switch-token", tailscaleOnly: true)
        XCTAssertTrue(configured)
        await model.selectHome()
        model.setAppActive(true)
        await model.refreshNow()
        model.setAppActive(false)
        return model
    }

    func testATabShowsAtOnceThenLoads() async throws {
        let model = try await model()
        await model.selectSession(tabA)
        await model.selectSession(tabB)
        XCTAssertEqual(reads[tabA], 1)

        // Back to A: selected, with its last copy, before anything is fetched.
        let load = try XCTUnwrap(model.showSession(tabA))
        XCTAssertFalse(model.isHomeSelected)
        XCTAssertEqual(model.selectedSessionID, tabA)
        XCTAssertEqual(model.selectedSession?.id, tabA)
        XCTAssertEqual(model.selectedSession?.transcript.last?.text, "Example answer in Example A")
        XCTAssertNil(model.showSession(tabA), "It's already showing")
        await model.loadSession(load)
        XCTAssertEqual(reads[tabA], 2, "The fresh copy still loads")

        // A tab never opened: selected at once, with nothing cached; asking again doesn't load it twice.
        let opening = try XCTUnwrap(model.showSession(tabC))
        XCTAssertEqual(model.selectedSessionID, tabC)
        XCTAssertNil(model.selectedSession)
        XCTAssertNil(model.showSession(tabC), "Already loading")
        await model.loadSession(opening)
        XCTAssertEqual(model.selectedSession?.id, tabC)
        XCTAssertEqual(reads[tabC], 1)

        // A switch that's overtaken leaves the later one in place.
        let stale = try XCTUnwrap(model.showSession(tabA))
        let latest = try XCTUnwrap(model.showSession(tabB))
        await model.loadSession(stale)
        XCTAssertEqual(model.selectedSessionID, tabB)
        await model.loadSession(latest)
        XCTAssertEqual(model.selectedSession?.id, tabB)
    }

    func testHomeShowsItsLastCopyAtOnceEvenAfterTheListRefreshes() async throws {
        let model = try await model()
        await model.selectSession(tabA)
        // A list refresh while a tab is open keeps Home's last copy.
        model.setAppActive(true)
        await model.refreshNow()
        model.setAppActive(false)
        let homeReads = reads[homeID] ?? 0
        let load = try XCTUnwrap(model.showHome())
        XCTAssertTrue(model.isHomeSelected)
        XCTAssertEqual(model.selectedSession?.isCantripHome, true)
        XCTAssertEqual(model.selectedSessionID, homeID)
        XCTAssertEqual(model.selectedSession?.transcript.last?.text, "Example answer in Cantrip Home")
        XCTAssertNil(model.showHome())
        await model.loadHome(load)
        XCTAssertEqual(reads[homeID], homeReads + 1)
        XCTAssertTrue(model.isHomeSelected)
    }

    func testALaneSwitchKeepsAConversationTheModelAlreadyShows() async throws {
        let model = try await model()
        await model.selectSession(tabA)
        await model.selectHome()
        let env = HermesEnv()
        env.select(.home)
        let vm = ChatViewModel(env: env, remote: model, voice: VoiceController())
        vm.syncRemoteTranscript()
        XCTAssertEqual(vm.turns.last?.text, "Example answer in Cantrip Home")

        // The Mac's sidebar: the tab, then the lane, in one update; its messages are on screen at once.
        _ = model.showSession(tabA)
        env.select(.cantrip)
        vm.switchLane(to: .cantrip)
        XCTAssertEqual(vm.turns.map(\.text), ["Example question in Example A", "Example answer in Example A"])

        // And back to Home.
        _ = model.showHome()
        env.select(.home)
        vm.switchLane(to: .home)
        XCTAssertEqual(vm.turns.last?.text, "Example answer in Cantrip Home")

        // A lane switch the model hasn't shown yet still starts empty, as before.
        env.select(.cantrip)
        vm.switchLane(to: .cantrip)
        XCTAssertTrue(vm.turns.isEmpty)
    }
}
