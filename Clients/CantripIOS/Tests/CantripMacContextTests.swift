import Foundation
import XCTest
@testable import Hermes

final class CantripMacContextTests: XCTestCase {
    private let context = CantripMacContext(
        selection: .init(text: "let x = 1", appName: "Xcode"),
        screenshots: [.init(path: "/Users/me/.cache/Cantrip/screen-1-d1.jpg", index: 1, isMain: true)]
    )

    func testOwnMacThatTakesItGetsTheContextAndThePlainText() {
        let route = CantripRemoteAPI.macContextRoute("Explain this", context: context, isOwnMac: true, supported: true)
        XCTAssertEqual(route.text, "Explain this")
        XCTAssertEqual(route.context, context)
    }

    func testAnotherMacGetsTheSelectionAsTextAndNoScreenshots() {
        for (own, supported) in [(false, true), (false, false), (true, false)] {
            let route = CantripRemoteAPI.macContextRoute("Explain this", context: context, isOwnMac: own,
                                                         supported: supported)
            XCTAssertNil(route.context)
            XCTAssertEqual(route.text, "Explain this\n\n(Selected text from Xcode, which my request refers to:\n\"\"\"\nlet x = 1\n\"\"\")")
        }
    }

    func testNoSelectionLeavesTheTextAlone() {
        let screenOnly = CantripMacContext(selection: nil, screenshots: context.screenshots)
        XCTAssertEqual(CantripRemoteAPI.macContextRoute("Hi", context: screenOnly, isOwnMac: false, supported: true).text, "Hi")
        XCTAssertEqual(CantripRemoteAPI.macContextRoute("Hi", context: nil, isOwnMac: true, supported: true).text, "Hi")
    }

    func testInlineSelectionIsCappedLikeThePanel() {
        let long = CantripMacContext.Selection(text: String(repeating: "a", count: 5000), appName: "Notes")
        let text = CantripMacContext.inline(long, after: "Q")
        XCTAssertTrue(text.contains(String(repeating: "a", count: 4000) + "\n\"\"\")"))
        XCTAssertFalse(text.contains(String(repeating: "a", count: 4001)))
    }

    func testMessageBodyCarriesMacContextOnlyWhenGiven() throws {
        let sent = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            CantripMessageBody(text: "Q", mode: .auto, images: [], macContext: context)
        )) as? [String: Any]
        let mac = try XCTUnwrap(sent?["macContext"] as? [String: Any])
        XCTAssertEqual(mac["selection"] as? [String: String], ["text": "let x = 1", "appName": "Xcode"])
        let shots = try XCTUnwrap(mac["screenshots"] as? [[String: Any]])
        XCTAssertEqual(shots.first?["path"] as? String, "/Users/me/.cache/Cantrip/screen-1-d1.jpg")
        XCTAssertEqual(shots.first?["index"] as? Int, 1)
        XCTAssertEqual(shots.first?["isMain"] as? Bool, true)
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            CantripMessageBody(text: "Q", mode: .auto, images: [])
        )) as? [String: Any]
        XCTAssertNil(plain?["macContext"])
    }

    func testOwnMacIsTheLoopbackServerWithTheLocalKey() throws {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:18765"))
        let api = CantripRemoteAPI(transport: .remote(url), token: "t")
        XCTAssertFalse(api.isOwnMac)
        CantripLocalClientKey.register("local-key", for: url.absoluteString)
        addTeardownBlock { CantripLocalClientKey.register(nil, for: url.absoluteString) }
        XCTAssertTrue(api.isOwnMac)
        let other = CantripRemoteAPI(transport: .remote(try XCTUnwrap(URL(string: "https://studio.example"))), token: "t")
        XCTAssertFalse(other.isOwnMac)
    }
}
