import XCTest
@testable import Hermes

final class CantripBrowserPreviewTests: XCTestCase {
    func testActivityBrowserFlagIsOptional() throws {
        let marked = try JSONDecoder().decode(CantripRemoteActivity.self, from: Data(
            #"{"id":"a","title":"Open site","toolName":"browser-tab_open","state":"running","browser":true}"#.utf8))
        XCTAssertEqual(marked.browser, true)
        // Older Macs don't send the flag.
        let plain = try JSONDecoder().decode(CantripRemoteActivity.self, from: Data(
            #"{"id":"b","title":"ls","toolName":"bash","state":"succeeded"}"#.utf8))
        XCTAssertNil(plain.browser)
    }

    func testFrameDecodesBase64Image() throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        let json = #"{"data":"\#(jpeg.base64EncodedString())","width":640,"height":400,"url":"https://example.com/","title":"Example Domain","active":true,"capturedAt":"2026-10-31T02:30:39Z"}"#
        let frame = try JSONDecoder().decode(CantripBrowserFrame.self, from: Data(json.utf8))
        XCTAssertEqual(frame.data, jpeg)
        XCTAssertEqual(frame.width, 640)
        XCTAssertTrue(frame.active)
        XCTAssertEqual(frame.title, "Example Domain")
        // Older Macs don't send seq.
        XCTAssertNil(frame.seq)
        let streamed = try JSONDecoder().decode(CantripBrowserFrame.self, from: Data(
            json.replacingOccurrences(of: "}", with: #","seq":42}"#).utf8))
        XCTAssertEqual(streamed.seq, 42)
    }

    func testFrameRequestsWaitForChangesWithALongerTimeout() {
        XCTAssertEqual(CantripRemoteAPI.browserFramePath(width: 960, after: nil), "/api/v1/browser/frame?width=960")
        XCTAssertEqual(CantripRemoteAPI.browserFramePath(width: 5000, after: 42), "/api/v1/browser/frame?width=1920&after=42")
        XCTAssertEqual(CantripRemoteAPI.browserFramePath(width: 10, after: 0), "/api/v1/browser/frame?width=240")
        // The Mac holds a request with `after` for up to 8 s: it must not get the 2-3 s read timeout.
        XCTAssertTrue(CantripRemoteAPI.isContentRead(method: "GET", path: "/api/v1/browser/frame?width=960&after=42"))
        XCTAssertFalse(CantripRemoteAPI.isContentRead(method: "GET", path: "/api/v1/browser"))
    }
}
