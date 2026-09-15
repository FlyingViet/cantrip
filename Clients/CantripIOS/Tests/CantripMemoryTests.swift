import SwiftUI
import UIKit
import XCTest
@testable import Hermes

private final class MemoryRequestProtocol: URLProtocol {
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
}

@MainActor
final class CantripMemoryTests: XCTestCase {
    private func client() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MemoryRequestProtocol.self]
        let client = URLSession(configuration: configuration)
        addTeardownBlock { @MainActor in
            client.invalidateAndCancel()
            MemoryRequestProtocol.handler = nil
        }
        return client
    }

    private func api() -> CantripRemoteAPI {
        CantripRemoteAPI(transport: .remote(URL(string: "https://cantrip.example")!),
                         token: "memory-test-token", urlSession: client())
    }

    private func entry(_ id: String = "MEMORY.md") -> CantripMemoryEntry {
        CantripMemoryEntry(id: id, category: .core, bytes: 100, modifiedAt: 1_800_000_000, characterLimit: 2200)
    }

    private func catalog(_ ids: [String], next: String? = nil) -> CantripMemoryCatalog {
        CantripMemoryCatalog(enabled: true, exists: true, documents: ids.map(entry), nextCursor: next)
    }

    private func page(offset: Int = 0, next: Int? = nil, revision: String = "r1") -> CantripMemoryPage {
        CantripMemoryPage(document: entry(), text: "Page \(offset)", offset: offset, nextOffset: next, revision: revision)
    }

    private func catalogData(id: String = "MEMORY.md") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "enabled": true, "exists": true,
            "documents": [["id": id, "category": "core", "bytes": 100, "modifiedAt": 1_800_000_000, "characterLimit": 2200]],
        ])
    }

    private func pageData(id: String = "MEMORY.md", offset: Int = 0, next: Int? = nil,
                          text: String = "# Saved facts\nOriginal memory") throws -> Data {
        var value: [String: Any] = [
            "document": ["id": id, "category": "core", "bytes": max(100, text.utf8.count),
                         "modifiedAt": 1_800_000_000, "characterLimit": 2200],
            "text": text, "offset": offset, "revision": "r1",
        ]
        value["nextOffset"] = next
        return try JSONSerialization.data(withJSONObject: value)
    }

    func testCatalogAndDocumentArePairedReadOnlyAndUseContentDeadline() async throws {
        let api = api()
        var calls = 0
        MemoryRequestProtocol.handler = { request in
            calls += 1
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer memory-test-token")
            XCTAssertEqual(request.timeoutInterval, 20)
            XCTAssertNil(request.httpBody)
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            if request.url!.path == "/api/v1/memory" {
                XCTAssertEqual(items.first { $0.name == "q" }?.value, "spaces & notes")
                XCTAssertEqual(items.first { $0.name == "after" }?.value, "sessions/2026-09-15.md")
                return (200, try self.catalogData())
            }
            XCTAssertEqual(request.url!.path, "/api/v1/memory/document")
            XCTAssertEqual(items.first { $0.name == "id" }?.value, "saved & useful.md")
            XCTAssertEqual(items.first { $0.name == "revision" }?.value, "r1")
            return (200, try self.pageData(id: "saved & useful.md", offset: 10))
        }
        let snapshot = try await api.memoryCatalog(query: "spaces & notes", after: "sessions/2026-09-15.md")
        XCTAssertEqual(snapshot.documents.first?.title, "Environment & conventions")
        XCTAssertEqual(snapshot.documents.first?.characterLimit, 2200)
        let content = try await api.memoryDocument(id: "saved & useful.md", offset: 10, revision: "r1")
        XCTAssertEqual(content.text, "# Saved facts\nOriginal memory")
        XCTAssertEqual(calls, 2, "Listing files does not prefetch any document")
        XCTAssertTrue(CantripRemoteAPI.isContentRead(method: "GET", path: "/api/v1/memory/document?id=USER.md"))
        XCTAssertFalse(CantripRemoteAPI.isContentRead(method: "POST", path: "/api/v1/memory"))
        XCTAssertFalse(CantripRemoteAPI.isContentRead(method: "GET", path: "/api/v1/github/builds"))
    }

    func testUnsupportedHostsAuthenticationAndMissingFilesStayDistinct() async throws {
        let api = api()
        MemoryRequestProtocol.handler = { _ in (404, Data(#"{"error":"not found"}"#.utf8)) }
        do {
            _ = try await api.memoryCatalog(query: "", after: nil)
            XCTFail("An old host needs a visible update notice")
        } catch CantripRemoteError.memoryUnsupported {}
        do {
            _ = try await api.memoryDocument(id: "missing.md", offset: 0, revision: nil)
            XCTFail("A missing file is not an unsupported-host response")
        } catch CantripRemoteError.http(404, _) {}
        MemoryRequestProtocol.handler = { _ in (401, Data(#"{"error":"unauthorized"}"#.utf8)) }
        do {
            _ = try await api.memoryCatalog(query: "", after: nil)
            XCTFail("Pairing failures cannot appear as empty memory")
        } catch CantripRemoteError.authentication {}
        MemoryRequestProtocol.handler = { _ in (200, Data(#"{"documents":[]}"#.utf8)) }
        do {
            _ = try await api.memoryCatalog(query: "", after: nil)
            XCTFail("Malformed snapshots must surface")
        } catch CantripRemoteError.decoding {}
    }

    func testInvalidDocumentIdentityOrNonAdvancingPageIsRejected() async throws {
        let api = api()
        for response in [try pageData(id: "USER.md"), try pageData(next: 0), try pageData(offset: 1)] {
            MemoryRequestProtocol.handler = { _ in (200, response) }
            do {
                _ = try await api.memoryDocument(id: "MEMORY.md", offset: 0, revision: nil)
                XCTFail("An invalid page must not be presented")
            } catch CantripRemoteError.invalidResponse {}
        }
    }

    func testCatalogPagesOnRequestAndPreservesListOnFailure() async {
        let model = CantripMemoryCatalogModel()
        var calls = 0
        await model.load(query: "") { _, cursor in
            calls += 1
            XCTAssertNil(cursor)
            return self.catalog(["MEMORY.md", "USER.md"], next: "USER.md")
        }
        XCTAssertEqual(calls, 1)
        await model.load(query: "", more: true) { _, cursor in
            calls += 1
            XCTAssertEqual(cursor, "USER.md")
            return self.catalog(["self.md"])
        }
        XCTAssertEqual(model.catalog?.documents.map(\.id), ["MEMORY.md", "USER.md", "self.md"])
        await model.load(query: "", more: true) { _, _ in
            XCTFail("No next cursor means no further requests")
            return self.catalog([])
        }
        await model.load(query: "") { _, _ in throw CantripRemoteError.transport("Offline") }
        XCTAssertEqual(model.catalog?.documents.count, 3)
        XCTAssertTrue(model.error?.contains("Offline") == true)
        await model.load(query: "") { _, _ in throw CancellationError() }
        XCTAssertTrue(model.error?.contains("Offline") == true)
        await model.load(query: "none") { _, _ in self.catalog([]) }
        XCTAssertTrue(model.catalog?.documents.isEmpty == true)
        XCTAssertNil(model.error)
    }

    func testNewSearchSupersedesSlowOldResultAndCoalescesMore() async throws {
        let model = CantripMemoryCatalogModel()
        var release: CheckedContinuation<CantripMemoryCatalog, Never>?
        let first = Task {
            await model.load(query: "old") { _, _ in await withCheckedContinuation { release = $0 } }
        }
        for _ in 0..<100 {
            if release != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(release)
        await model.load(query: "old", more: true) { _, _ in
            XCTFail("Repeated pagination must not duplicate an in-flight request")
            return self.catalog([])
        }
        await model.load(query: "new") { _, _ in self.catalog(["new.md"]) }
        release?.resume(returning: catalog(["old.md"]))
        await first.value
        XCTAssertEqual(model.catalog?.documents.map(\.id), ["new.md"])
        XCTAssertFalse(model.isLoading)
    }

    func testReaderKeepsPageAndRevisionUntilExplicitReload() async {
        let model = CantripMemoryReaderModel()
        await model.load(.reload) { offset, revision in
            XCTAssertEqual(offset, 0)
            XCTAssertNil(revision)
            return self.page(next: 10)
        }
        await model.load(.next) { offset, revision in
            XCTAssertEqual(offset, 10)
            XCTAssertEqual(revision, "r1")
            return self.page(offset: 10, next: 20)
        }
        XCTAssertEqual(model.pageIndex, 1)
        await model.load(.previous) { offset, revision in
            XCTAssertEqual(offset, 0)
            XCTAssertEqual(revision, "r1")
            return self.page(next: 10)
        }
        XCTAssertEqual(model.pageIndex, 0)
        await model.load(.next) { _, _ in throw CantripRemoteError.http(409, "File changed") }
        XCTAssertEqual(model.page?.text, "Page 0")
        XCTAssertTrue(model.error?.contains("File changed") == true)
        await model.load(.reload) { offset, revision in
            XCTAssertEqual(offset, 0)
            XCTAssertNil(revision)
            return self.page(revision: "r2")
        }
        XCTAssertEqual(model.page?.revision, "r2")
        XCTAssertNil(model.error)
        await model.load(.next) { _, _ in
            XCTFail("The last page must not request more text")
            return self.page()
        }
    }

    func testServerChangesRejectLateMemoryReads() async throws {
        let remote = CantripRemoteModel(urlSession: client())
        addTeardownBlock { @MainActor in remote.clearConfiguration() }
        let configured = await remote.configure(url: "https://first.example", pairingToken: "memory-token", tailscaleOnly: true)
        XCTAssertTrue(configured)
        let identity = remote.usageIdentity
        var release: CheckedContinuation<Void, Never>?
        MemoryRequestProtocol.handler = { _ in
            await withCheckedContinuation { release = $0 }
            return (200, try self.catalogData())
        }
        let read = Task { try await remote.memoryCatalog(query: "", after: nil) }
        for _ in 0..<100 {
            if release != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(release)
        let changed = await remote.configure(url: "https://second.example", pairingToken: "second-token", tailscaleOnly: true)
        XCTAssertTrue(changed)
        XCTAssertNotEqual(remote.usageIdentity, identity, "The browser resets when its connected server changes")
        release?.resume()
        do {
            _ = try await read.value
            XCTFail("A previous server's saved memory must never appear under the new server")
        } catch is CancellationError {}
    }

    func testReaderRendersSavedTextWithoutExternalContentOrHorizontalOverflow() async throws {
        let remote = CantripRemoteModel(urlSession: client())
        addTeardownBlock { @MainActor in remote.clearConfiguration() }
        let configured = await remote.configure(url: "https://cantrip.example", pairingToken: "memory-token", tailscaleOnly: true)
        XCTAssertTrue(configured)
        var calls = 0
        MemoryRequestProtocol.handler = { request in
            calls += 1
            XCTAssertEqual(request.url?.host, "cantrip.example")
            XCTAssertEqual(request.url?.path, "/api/v1/memory/document")
            return (200, try self.pageData(text: "# Saved memory\n![External](https://outside.example/image.png)\n"
                                          + String(repeating: "Saved text and preferences. ", count: 400)))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: NavigationStack {
            CantripMemoryReader(remote: remote, entry: entry()).frame(width: 320, height: 600)
        })
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(600))
        controller.view.layoutIfNeeded()
        func findScroll(_ view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView { return scroll }
            return view.subviews.lazy.compactMap(findScroll).first
        }
        let scroll = try XCTUnwrap(findScroll(controller.view))
        XCTAssertGreaterThan(scroll.contentSize.height, 600)
        XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
        XCTAssertEqual(calls, 1, "The viewer requests only the selected file, not external Markdown resources")
        let renderer = UIGraphicsImageRenderer(bounds: controller.view.bounds)
        let screenshot = renderer.image { _ in controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: screenshot)
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
