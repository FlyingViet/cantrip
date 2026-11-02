import Network
import XCTest
@testable import Hermes

private final class ArtifactDownloadRequestProtocol: URLProtocol {
    @MainActor static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Task { @MainActor in
            do {
                let handler = try XCTUnwrap(Self.handler)
                let (status, headers, data) = try handler(request)
                let response = try XCTUnwrap(HTTPURLResponse(
                    url: try XCTUnwrap(request.url), statusCode: status,
                    httpVersion: "HTTP/1.1", headerFields: headers
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

/// A one-shot TLS-PSK server like the Mac's LAN listener; `respond` gets the request head.
private final class ArtifactLANServer: @unchecked Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "artifact-lan-server")
    private var connections: [NWConnection] = []
    var requestHead = ""

    init(token: String, respond: @escaping (String) -> [Data]) throws {
        listener = try NWListener(using: CantripLANProtocol.parameters(token: token), on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.read(connection, buffer: Data(), respond: respond)
        }
    }

    func start() async throws -> NWEndpoint.Port {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NWEndpoint.Port, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { [listener] state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume(returning: listener.port!)
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.sync {
            listener.cancel()
            connections.forEach { $0.cancel() }
        }
    }

    private func read(_ connection: NWConnection, buffer: Data, respond: @escaping (String) -> [Data]) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, error in
            guard let self, error == nil else { return }
            let buffer = buffer + (data ?? Data())
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                self.read(connection, buffer: buffer, respond: respond)
                return
            }
            self.requestHead = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            self.send(respond(self.requestHead)[...], on: connection)
        }
    }

    private func send(_ pieces: ArraySlice<Data>, on connection: NWConnection) {
        guard let piece = pieces.first else {
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        connection.send(content: piece, completion: .contentProcessed { [weak self] _ in
            self?.send(pieces.dropFirst(), on: connection)
        })
    }
}

@MainActor
final class CantripArtifactDownloadTests: XCTestCase {
    private let artifactID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-download-tests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func payload(_ size: Int) -> Data {
        Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 9) })
    }

    func testFolderAndFileNameComeFromTheRelativePath() {
        func artifact(_ path: String) -> CantripHomeArtifact {
            CantripHomeArtifact(id: UUID(), title: "Graph", relativePath: path, kind: "document",
                                mimeType: "text/html", size: 1, createdAt: Date())
        }
        XCTAssertNil(artifact("report.md").folder)
        XCTAssertEqual(artifact("report.md").fileName, "report.md")
        XCTAssertEqual(artifact("ddia-knowledge-graph/graph.html").folder, "ddia-knowledge-graph")
        XCTAssertEqual(artifact("ddia-knowledge-graph/data/graph.json").folder, "ddia-knowledge-graph")
        XCTAssertEqual(artifact("ddia-knowledge-graph/data/graph.json").fileName, "graph.json")
    }

    func testContentDispositionNamesAreDecodedAndMadeSafe() {
        XCTAssertEqual(CantripContentDisposition.fileName(
            #"attachment; filename="Playbook _.md"; filename*=UTF-8''Playbook%20%E2%9C%93.md"#
        ), "Playbook ✓.md")
        XCTAssertEqual(CantripContentDisposition.fileName(#"attachment; filename="report.pdf""#), "report.pdf")
        XCTAssertEqual(CantripContentDisposition.fileName(
            #"attachment; filename*=UTF-8''..%2F..%2Fetc%2Fpasswd"#
        ), "passwd")
        XCTAssertEqual(CantripContentDisposition.fileName(#"attachment; filename="a:b.txt""#), "a_b.txt")
        XCTAssertNil(CantripContentDisposition.fileName(#"attachment; filename=".hidden""#))
        XCTAssertNil(CantripContentDisposition.fileName("attachment"))
        XCTAssertNil(CantripContentDisposition.fileName(nil))
    }

    func testTailscaleRouteDownloadsTheFileToDiskWithTheMacsName() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtifactDownloadRequestProtocol.self]
        let client = URLSession(configuration: configuration)
        addTeardownBlock { @MainActor in
            client.invalidateAndCancel()
            ArtifactDownloadRequestProtocol.handler = nil
        }
        let api = CantripRemoteAPI(
            transport: .remote(try XCTUnwrap(URL(string: "https://cantrip.example"))),
            token: "home-token", urlSession: client
        )
        let body = payload(2 * 1024 * 1024 + 7)
        var paths: [String] = []
        ArtifactDownloadRequestProtocol.handler = { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer home-token")
            if path.hasSuffix("/file") {
                return (200, ["Content-Type": "video/mp4", "Content-Length": "\(body.count)",
                              "Content-Disposition": #"attachment; filename="clip.mp4"; filename*=UTF-8''clip.mp4"#], body)
            }
            if path.hasSuffix("/folder") {
                return (404, ["Content-Type": "application/json"], Data(#"{"error":"This artifact isn't in a folder."}"#.utf8))
            }
            return (401, ["Content-Type": "application/json"], Data(#"{"error":"invalid pairing token"}"#.utf8))
        }
        let folder = try directory()
        let file = try await api.downloadHomeArtifact(
            id: artifactID, folder: false, fallbackName: "fallback.bin", into: folder
        )
        XCTAssertEqual(file.lastPathComponent, "clip.mp4")
        XCTAssertEqual(try Data(contentsOf: file), body)
        XCTAssertEqual(paths, ["/api/v1/home/artifacts/\(artifactID.uuidString)/file"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["clip.mp4"],
                       "no partial or temporary files are left behind")
        do {
            _ = try await api.downloadHomeArtifact(id: artifactID, folder: true, fallbackName: "x.zip", into: folder)
            XCTFail("A host refusal must throw")
        } catch CantripRemoteError.http(let status, let message) {
            XCTAssertEqual(status, 404)
            XCTAssertEqual(message, "This artifact isn't in a folder.")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["clip.mp4"])
    }

    func testLANRouteStreamsTheBodyToDiskOverTLSPSK() async throws {
        let body = payload(3 * 1024 * 1024 + 11)
        let server = try ArtifactLANServer(token: "lan-token") { _ in
            let head = "HTTP/1.1 200 OK\r\nContent-Type: application/zip\r\nContent-Length: \(body.count)\r\n"
                + "Content-Disposition: attachment; filename=\"ddia.zip\"; filename*=UTF-8''ddia.zip\r\nConnection: close\r\n\r\n"
            return [Data(head.utf8) + body.prefix(1000)] + stride(from: 1000, to: body.count, by: 512 * 1024).map {
                body.subdata(in: $0..<min($0 + 512 * 1024, body.count))
            }
        }
        let port = try await server.start()
        defer { server.stop() }
        let api = CantripRemoteAPI(transport: .lan(.hostPort(host: "127.0.0.1", port: port)), token: "lan-token")
        let folder = try directory()
        let file = try await api.downloadHomeArtifact(
            id: artifactID, folder: true, fallbackName: "fallback.zip", into: folder
        )
        XCTAssertEqual(file.lastPathComponent, "ddia.zip")
        XCTAssertEqual(try Data(contentsOf: file), body)
        XCTAssertTrue(server.requestHead.hasPrefix("GET /api/v1/home/artifacts/\(artifactID.uuidString)/folder HTTP/1.1"))
        XCTAssertTrue(server.requestHead.contains("Authorization: Bearer lan-token"))
        XCTAssertFalse(server.requestHead.lowercased().contains("accept-encoding"), "downloads are never gzipped")
    }

    func testLANRouteReportsHostErrorsAndTruncatedBodies() async throws {
        let refusal = try ArtifactLANServer(token: "lan-token") { _ in
            let json = Data(#"{"error":"Artifact not found."}"#.utf8)
            return [Data("HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\n\r\n".utf8) + json]
        }
        let refusalPort = try await refusal.start()
        defer { refusal.stop() }
        let folder = try directory()
        do {
            _ = try await CantripRemoteAPI(transport: .lan(.hostPort(host: "127.0.0.1", port: refusalPort)), token: "lan-token")
                .downloadHomeArtifact(id: artifactID, folder: false, fallbackName: "a.md", into: folder)
            XCTFail("A 404 must throw")
        } catch CantripRemoteError.http(let status, let message) {
            XCTAssertEqual(status, 404)
            XCTAssertEqual(message, "Artifact not found.")
        }

        let truncated = try ArtifactLANServer(token: "lan-token") { _ in
            [Data("HTTP/1.1 200 OK\r\nContent-Length: 5000\r\n\r\n".utf8) + Data(repeating: 1, count: 1000)]
        }
        let truncatedPort = try await truncated.start()
        defer { truncated.stop() }
        do {
            _ = try await CantripRemoteAPI(transport: .lan(.hostPort(host: "127.0.0.1", port: truncatedPort)), token: "lan-token")
                .downloadHomeArtifact(id: artifactID, folder: false, fallbackName: "a.md", into: folder)
            XCTFail("A short body must throw")
        } catch {
            XCTAssertTrue(CantripRemoteError.isRouteFailure(error), "\(error)")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [],
                       "failed downloads leave nothing behind")
    }

    func testDownloadFoldersAreDiscardedOnlyInsideTheirRoot() throws {
        let made = try CantripArtifactDownloadFolder.make()
        let file = made.appendingPathComponent("a.txt")
        try Data("a".utf8).write(to: file)
        let outside = try directory()
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let kept = outside.appendingPathComponent("b.txt")
        try Data("b".utf8).write(to: kept)
        CantripArtifactDownloadFolder.discard(kept)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        CantripArtifactDownloadFolder.discard(file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: made.path))
    }
}
