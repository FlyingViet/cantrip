import Foundation

extension SessionTabTests {
    /// Artifact downloads: the original bytes streamed from disk, folder zips of registered
    /// artifacts only, and nothing outside the artifacts folder, through the paired API.
    @MainActor
    static func testCantripHomeArtifactDownloads(
        store: CantripHomeStore, image: CantripHomeArtifact, imageData: Data,
        port: Int, token: String, client: URLSession
    ) async throws {
        func raw(_ path: String, method: String = "GET", authorized: Bool = true)
            async throws -> (Int, Data, HTTPURLResponse) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.httpMethod = method
            if authorized { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (data, response) = try await client.data(for: request)
            let http = response as! HTTPURLResponse
            return (http.statusCode, data, http)
        }
        func errorText(_ data: Data) -> String {
            ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String ?? ""
        }
        let root = CantripHomeStore.artifactDirectory
        let base = "/api/v1/home/artifacts"

        let listed = try await raw(base)
        let snapshot = (try JSONSerialization.jsonObject(with: listed.1)) as? [String: Any]
        precondition(snapshot?["supportsDownloads"] as? Bool == true, "the list advertises downloads")

        let file = try await raw("\(base)/\(image.id.uuidString)/file")
        precondition(file.0 == 200 && file.1 == imageData
                     && file.2.value(forHTTPHeaderField: "Content-Type") == "image/png"
                     && file.2.value(forHTTPHeaderField: "Content-Length") == "\(imageData.count)"
                     && file.2.value(forHTTPHeaderField: "Content-Disposition")
                        == #"attachment; filename="home-test.png"; filename*=UTF-8''home-test.png"#
                     && file.2.value(forHTTPHeaderField: "Cache-Control") == "no-store",
                     "a file download is the original bytes as an attachment: \(file.2.allHeaderFields)")
        let anonymous = try await raw("\(base)/\(image.id.uuidString)/file", authorized: false)
        let anonymousFolder = try await raw("\(base)/\(image.id.uuidString)/folder", authorized: false)
        let wrongMethod = try await raw("\(base)/\(image.id.uuidString)/file", method: "POST")
        let unknown = try await raw("\(base)/\(UUID().uuidString)/file")
        let notUUID = try await raw("\(base)/..%2F..%2Fsecrets/file")
        let topLevelFolder = try await raw("\(base)/\(image.id.uuidString)/folder")
        precondition(anonymous.0 == 401 && anonymousFolder.0 == 401 && wrongMethod.0 == 405
                     && unknown.0 == 404 && notUUID.0 == 404 && topLevelFolder.0 == 404
                     && errorText(topLevelFolder.1) == "This artifact isn't in a folder.",
                     "downloads need pairing, GET and a registered artifact id")

        // Several pieces: the stream must arrive whole and in order.
        let folder = root.appendingPathComponent("download-test-folder", isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("data"), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: folder) }
        var large = Data(count: 3 * 1024 * 1024 + 123)
        large.withUnsafeMutableBytes { buffer in
            for index in buffer.indices { buffer[index] = UInt8(truncatingIfNeeded: index &* 31 &+ index >> 9) }
        }
        try large.write(to: folder.appendingPathComponent("graph.html"))
        try Data("# Playbook ✓\n".utf8).write(to: folder.appendingPathComponent("Playbook ✓.md"))
        try Data(#"{"nodes":[]}"#.utf8).write(to: folder.appendingPathComponent("data/graph.json"))
        try Data("not registered".utf8).write(to: folder.appendingPathComponent("private.txt"))
        let graph = try store.register(.init(title: "Graph", path: "download-test-folder/graph.html", kind: nil))
        let playbook = try store.register(.init(title: "Playbook", path: "download-test-folder/Playbook ✓.md", kind: nil))
        let data = try store.register(.init(title: "Data", path: "download-test-folder/data/graph.json", kind: nil))
        defer { for id in [graph.id, playbook.id, data.id] { try? store.deleteArtifact(id: id) } }

        let largeFile = try await raw("\(base)/\(graph.id.uuidString)/file")
        precondition(largeFile.0 == 200 && largeFile.1 == large, "a multi-piece file streams intact")
        let unicode = try await raw("\(base)/\(playbook.id.uuidString)/file")
        precondition(unicode.2.value(forHTTPHeaderField: "Content-Disposition")
                        == #"attachment; filename="Playbook _.md"; filename*=UTF-8''Playbook%20%E2%9C%93.md"#
                     && unicode.2.value(forHTTPHeaderField: "Content-Type") == "text/markdown",
                     "non-ASCII names keep their UTF-8 form: \(unicode.2.allHeaderFields)")

        let zip = try await raw("\(base)/\(data.id.uuidString)/folder")
        precondition(zip.0 == 200 && zip.2.value(forHTTPHeaderField: "Content-Type") == "application/zip"
                     && zip.2.value(forHTTPHeaderField: "Content-Length") == "\(zip.1.count)"
                     && zip.2.value(forHTTPHeaderField: "Content-Disposition")?
                        .hasPrefix(#"attachment; filename="download-test-folder.zip""#) == true,
                     "a folder downloads as one zip: \(zip.2.allHeaderFields)")
        let unpacked = try unzipForTest(zip.1)
        defer { try? FileManager.default.removeItem(at: unpacked.deletingLastPathComponent()) }
        let top = unpacked.appendingPathComponent("download-test-folder")
        let names = try FileManager.default.subpathsOfDirectory(atPath: top.path).sorted()
        precondition(names == ["Playbook ✓.md", "data", "data/graph.json", "graph.html"],
                     "the zip holds only the folder's registered artifacts: \(names)")
        let unpackedGraph = try Data(contentsOf: top.appendingPathComponent("graph.html"))
        let unpackedPlaybook = try Data(contentsOf: top.appendingPathComponent("Playbook ✓.md"))
        precondition(unpackedGraph == large
                     && String(decoding: unpackedPlaybook, as: UTF8.self) == "# Playbook ✓\n",
                     "zipped files open intact")

        // A registered file swapped for a link to a file outside the artifacts folder.
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("cantrip-download-outside-\(UUID().uuidString).txt")
        try Data("outside secret".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let swapped = folder.appendingPathComponent("data/graph.json")
        try FileManager.default.removeItem(at: swapped)
        try FileManager.default.createSymbolicLink(at: swapped, withDestinationURL: outside)
        let escaped = try await raw("\(base)/\(data.id.uuidString)/file")
        let escapedZip = try await raw("\(base)/\(graph.id.uuidString)/folder")
        let escapedUnpacked = try unzipForTest(escapedZip.1)
        defer { try? FileManager.default.removeItem(at: escapedUnpacked.deletingLastPathComponent()) }
        let escapedNames = try FileManager.default.subpathsOfDirectory(
            atPath: escapedUnpacked.appendingPathComponent("download-test-folder").path
        ).sorted()
        precondition(escaped.0 == 404 && !escaped.1.contains(Data("outside secret".utf8))
                     && escapedZip.0 == 200 && !escapedZip.1.contains(Data("outside secret".utf8))
                     && escapedNames == ["Playbook ✓.md", "graph.html"],
                     "a link out of the artifacts folder is never followed: \(escapedNames)")

        // The descriptor check alone (a path that passed validation, then became a link).
        let realRoot = try CantripHomeArtifactDownload.realPath(root)
        let direct = CantripHomeArtifactDownload(
            fileName: "graph.json", contentType: "application/json", root: root,
            entries: [.init(url: swapped, name: "graph.json", modified: Date())], isArchive: false
        )
        do {
            _ = try direct.makeBody()
            preconditionFailure("opening a link must fail")
        } catch let error as CantripHomeError {
            precondition(error.status == 404)
        }
        do {
            _ = try CantripHomeArtifactDownload.open(outside, realRoot: realRoot)
            preconditionFailure("files outside the artifacts folder must not open")
        } catch is CantripHomeError {}

        // A file that shrinks after it was measured ends the stream with an error, not short data.
        let shrinking = folder.appendingPathComponent("graph.html")
        let body = try CantripHomeArtifactDownload(
            fileName: "graph.html", contentType: "text/html", root: root,
            entries: [.init(url: shrinking, name: "graph.html", modified: Date())], isArchive: false
        ).makeBody()
        _ = try body.next(maxBytes: 1024)
        try Data("short".utf8).write(to: shrinking)
        var failed = false
        do { while try body.next(maxBytes: 1 << 20) != nil {} } catch { failed = true }
        precondition(failed, "a truncated source must fail the stream")

        // A registered file that grew past the zip limit (sparse, so nothing is written) is refused
        // up front, without reading it.
        let grown = folder.appendingPathComponent("grown.bin")
        try Data("small".utf8).write(to: grown)
        let grownArtifact = try store.register(.init(title: "Grown", path: "download-test-folder/grown.bin", kind: nil))
        defer { try? store.deleteArtifact(id: grownArtifact.id) }
        let sparse = try FileHandle(forWritingTo: grown)
        try sparse.truncate(atOffset: 5 * 1024 * 1024 * 1024)
        try sparse.close()
        let started = Date()
        let oversized = try await raw("\(base)/\(grownArtifact.id.uuidString)/folder")
        precondition(oversized.0 == 413 && Date().timeIntervalSince(started) < 5,
                     "an oversized folder is refused before reading it: \(oversized.0)")
        print("Cantrip Home artifact downloads: streamed files, folder zips and link guards passed")
    }

    static func unzipForTest(_ zip: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cantrip-unzip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archive = directory.appendingPathComponent("archive.zip")
        try zip.write(to: archive)
        let test = Process()
        test.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        test.arguments = ["-tqq", archive.path]
        try test.run()
        test.waitUntilExit()
        precondition(test.terminationStatus == 0, "unzip -t accepts the archive")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, directory.appendingPathComponent("out").path]
        try ditto.run()
        ditto.waitUntilExit()
        precondition(ditto.terminationStatus == 0, "Archive Utility's ditto unpacks the archive")
        try FileManager.default.removeItem(at: archive)
        return directory.appendingPathComponent("out")
    }
}
