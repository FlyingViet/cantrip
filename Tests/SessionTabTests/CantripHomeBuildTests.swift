import Foundation

extension SessionTabTests {
    /// Home's Builds tab: a read-only index of the Mac's over-the-air install page, grouped by
    /// page key like the page itself, with install links taken from each build's manifest.
    @MainActor
    static func testCantripHomeBuilds() async throws {
        let base = "https://phone.example.ts.net:8444"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cantrip-ota-tests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])

        @discardableResult
        func publish(
            in root: URL, bundle: String, folder: String, title: String, version: String = "1.0",
            build: String = "1", published: String, pageKey: String? = nil, icon: Bool = true,
            manifestBase: String? = nil, extra: [String: Any] = [:], ipa: Bool = true
        ) throws -> URL {
            let directory = root.appendingPathComponent("apps/\(bundle)/\(folder)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var meta: [String: Any] = [
                "bundle_id": bundle, "version": version, "build": build, "title": title,
                "note": "Built from main", "icon": icon, "size": 2_048, "size_label": "2.0 KB",
                "profile_name": "Ad Hoc profile", "profile_kind": "Ad Hoc", "profile_expires": "Sep 01, 2027",
                "team": "TEAM", "published_at": published, "published_label": "Oct 15, 6:30 PM",
                "source_commit": "abc123",
            ]
            if let pageKey { meta["page_key"] = pageKey }
            meta.merge(extra) { $1 }
            try JSONSerialization.data(withJSONObject: meta).write(to: directory.appendingPathComponent("meta.json"))
            let package = "\(manifestBase ?? base)/apps/\(bundle)/\(folder)/app.ipa"
            let manifest: [String: Any] = ["items": [[
                "assets": [["kind": "software-package", "url": package]],
                "metadata": ["bundle-identifier": bundle, "bundle-version": version, "kind": "software", "title": title],
            ]]]
            try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
                .write(to: directory.appendingPathComponent("manifest.plist"))
            if ipa { try Data("ipa".utf8).write(to: directory.appendingPathComponent("app.ipa")) }
            if icon { try png.write(to: directory.appendingPathComponent("icon.png")) }
            return directory
        }

        let missing = CantripHomeOTABuilds.snapshot(root: root)
        precondition(!missing.available && missing.apps.isEmpty && missing.pageURL == nil,
                     "A Mac without an install page reports it as unavailable")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("apps", isDirectory: true), withIntermediateDirectories: true
        )
        let empty = CantripHomeOTABuilds.snapshot(root: root)
        precondition(empty.available && empty.apps.isEmpty && empty.skipped == 0 && empty.pageURL == nil)

        // Two page entries share one bundle id (Brane Controller and Crooner).
        try publish(in: root, bundle: "com.example.shared", folder: "1.0-1-20261014090000", title: "Brane",
                    published: "2026-10-14T09:00:00-07:00", pageKey: "brane")
        let braneNew = try publish(in: root, bundle: "com.example.shared", folder: "1.0-2-20261015090000",
                                   title: "Brane Controller", build: "2",
                                   published: "2026-10-15T09:00:00-07:00", pageKey: "brane")
        try publish(in: root, bundle: "com.example.shared", folder: "1.0-1-20261015100000", title: "Crooner",
                    published: "2026-10-15T10:00:00-07:00", pageKey: "crooner")
        // No page key: grouped by bundle id; no icon; a UTC timestamp that sorts newest.
        try publish(in: root, bundle: "com.example.agent", folder: "1.0-100134-20261015183015",
                    title: "Cantrip Agent", build: "100134", published: "2026-10-16T01:30:15Z", icon: false)

        // The newest entry was published to another address; the page stays where most builds are.
        try publish(in: root, bundle: "com.example.elsewhere", folder: "1.0-1-20261017000000", title: "Elsewhere",
                    published: "2026-10-17T00:00:00Z", manifestBase: "https://other.example.ts.net:8444")

        // Unlistable folders are skipped and counted, never shown.
        let noMeta = root.appendingPathComponent("apps/com.example.broken/1.0-1-20261001000000", isDirectory: true)
        try FileManager.default.createDirectory(at: noMeta, withIntermediateDirectories: true)
        try publish(in: root, bundle: "com.example.broken", folder: "1.0-2-20261002000000", title: "No date",
                    published: "yesterday")
        try publish(in: root, bundle: "com.example.broken", folder: "1.0-3-20261003000000", title: "Elsewhere",
                    published: "2026-10-03T00:00:00Z", manifestBase: "http://phone.example.ts.net:8444")
        try publish(in: root, bundle: "com.example.broken", folder: "1.0-4-20261004000000", title: "No package",
                    published: "2026-10-04T00:00:00Z", ipa: false)
        let moved = try publish(in: root, bundle: "com.example.broken", folder: "1.0-5-20261005000000",
                                title: "Moved", published: "2026-10-05T00:00:00Z")
        let movedManifest: [String: Any] = ["items": [["assets": [[
            "kind": "software-package", "url": "\(base)/apps/com.example.other/1.0-5/app.ipa",
        ]]]]]
        try PropertyListSerialization.data(fromPropertyList: movedManifest, format: .xml, options: 0)
            .write(to: moved.appendingPathComponent("manifest.plist"))
        let linkedMeta = try publish(in: root, bundle: "com.example.broken", folder: "1.0-6-20261006000000",
                                     title: "Linked meta", published: "2026-10-06T00:00:00Z")
        let realMeta = root.appendingPathComponent("outside-meta.json")
        try FileManager.default.moveItem(at: linkedMeta.appendingPathComponent("meta.json"), to: realMeta)
        try FileManager.default.createSymbolicLink(at: linkedMeta.appendingPathComponent("meta.json"),
                                                   withDestinationURL: realMeta)
        // A symlinked build folder (outside the page) isn't followed or counted.
        let outside = try publish(in: root.appendingPathComponent("outside", isDirectory: true),
                                  bundle: "com.example.outside", folder: "1.0-1-20261007000000",
                                  title: "Outside", published: "2026-10-20T00:00:00Z")
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("apps/com.example.agent/1.0-9-20261020000000"),
            withDestinationURL: outside
        )

        let snapshot = CantripHomeOTABuilds.snapshot(root: root)
        precondition(snapshot.available && snapshot.skipped == 6, "Skipped: \(snapshot.skipped)")
        precondition(snapshot.apps.map(\.id) == ["com.example.elsewhere", "com.example.agent", "crooner", "brane"],
                     "Entries are ordered by their newest build: \(snapshot.apps.map(\.id))")
        precondition(snapshot.pageURL == base + "/", "The page is where most builds live, not an odd newest one")
        let brane = snapshot.apps[3]
        precondition(brane.title == "Brane Controller" && brane.bundleID == "com.example.shared"
                     && brane.builds.map(\.build) == ["2", "1"],
                     "An entry is titled by its newest build and lists builds newest first")
        let primary = brane.builds[0]
        let manifestURL = "\(base)/apps/com.example.shared/1.0-2-20261015090000/manifest.plist"
        precondition(primary.id == "com.example.shared/1.0-2-20261015090000"
                     && primary.manifestURL == manifestURL
                     && primary.installURL == "itms-services://?action=download-manifest&url="
                        + "https%3A%2F%2Fphone.example.ts.net%3A8444%2Fapps%2Fcom.example.shared%2F"
                        + "1.0-2-20261015090000%2Fmanifest.plist",
                     "Install links match the page's percent-encoded manifest links: \(primary.installURL)")
        precondition(primary.hasIcon && primary.size == 2_048 && primary.sizeLabel == "2.0 KB"
                     && primary.profileKind == "Ad Hoc" && primary.profileExpires == "Sep 01, 2027"
                     && primary.note == "Built from main" && primary.sourceCommit == "abc123"
                     && primary.publishedAt == ISO8601DateFormatter().date(from: "2026-10-15T16:00:00Z"))
        precondition(snapshot.apps[2].title == "Crooner" && snapshot.apps[2].builds.count == 1)
        precondition(snapshot.apps[1].builds.first?.hasIcon == false)

        let again = CantripHomeOTABuilds.snapshot(root: root)
        precondition(again.revision == snapshot.revision, "The revision is stable while nothing changes")
        try FileManager.default.removeItem(at: braneNew.appendingPathComponent("icon.png"))
        let changed = CantripHomeOTABuilds.snapshot(root: root)
        precondition(changed.revision != snapshot.revision && changed.apps[3].builds[0].hasIcon == false,
                     "A missing icon file is reported, not trusted from meta.json")

        // Icons: only a build folder's own regular PNG, addressed by the listed id.
        precondition(CantripHomeOTABuilds.iconData(id: "com.example.shared/1.0-1-20261014090000", root: root) == png)
        precondition(CantripHomeOTABuilds.iconData(id: primary.id, root: root) == nil)
        for id in ["../outside", "com.example.shared/..", "com.example.shared", "a/b/c", "/etc/x",
                   "com.example.shared/1.0-1-20261014090000/", ".hidden/x", "com.example.agent/1.0-9-20261020000000"] {
            precondition(CantripHomeOTABuilds.iconData(id: id, root: root) == nil, "Icon id \(id) must be rejected")
        }
        let crooner = root.appendingPathComponent("apps/com.example.shared/1.0-1-20261015100000/icon.png")
        try FileManager.default.removeItem(at: crooner)
        try FileManager.default.createSymbolicLink(
            at: crooner, withDestinationURL: root.appendingPathComponent("apps/com.example.shared/1.0-1-20261014090000/icon.png")
        )
        precondition(CantripHomeOTABuilds.iconData(id: "com.example.shared/1.0-1-20261015100000", root: root) == nil,
                     "Symlinked icons are not followed")
        let agentIcon = root.appendingPathComponent("apps/com.example.agent/1.0-100134-20261015183015/icon.png")
        try Data("not a png".utf8).write(to: agentIcon)
        precondition(CantripHomeOTABuilds.iconData(id: "com.example.agent/1.0-100134-20261015183015", root: root) == nil)
        try Data(png + Data(count: CantripHomeOTABuilds.maximumIconBytes)).write(to: agentIcon)
        precondition(CantripHomeOTABuilds.iconData(id: "com.example.agent/1.0-100134-20261015183015", root: root) == nil,
                     "Oversized icons are refused")

        // The authenticated API serves the default root: ~/Sites/ota under the test HOME.
        let pageRoot = CantripHomeOTABuilds.defaultRoot
        precondition(pageRoot.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path)
                     && !FileManager.default.fileExists(atPath: pageRoot.path))
        try publish(in: pageRoot, bundle: "com.example.shared", folder: "1.0-1-20261014090000", title: "Brane",
                    published: "2026-10-14T09:00:00-07:00", pageKey: "brane")
        try publish(in: pageRoot, bundle: "com.example.shared", folder: "1.0-2-20261015090000",
                    title: "Brane Controller", build: "2", published: "2026-10-15T09:00:00-07:00", pageKey: "brane")
        defer { try? FileManager.default.removeItem(at: pageRoot) }

        let previousEnabled = AppSettings.shared.cantripHomeEnabled
        AppSettings.shared.cantripHomeEnabled = true
        defer { AppSettings.shared.cantripHomeEnabled = previousEnabled }
        let manager = SessionManager()
        let server = RemoteControlServer(manager: manager)
        defer { withExtendedLifetime(manager) {} }
        let port = Int.random(in: 49152...65535)
        let token = UUID().uuidString
        server.start(port: port, token: token)
        defer { server.stop() }
        try await Task.sleep(for: .milliseconds(250))
        let client = URLSession(configuration: .ephemeral)
        defer { client.invalidateAndCancel() }
        func call(_ path: String, method: String = "GET", authorized: Bool = true) async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.httpMethod = method
            if authorized { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (data, response) = try await client.data(for: request)
            return ((response as! HTTPURLResponse).statusCode,
                    ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:])
        }

        let listed = try await call("/api/v1/home/builds")
        let apps = try requireHome(listed.1["apps"] as? [[String: Any]])
        let builds = try requireHome(apps.first?["builds"] as? [[String: Any]])
        precondition(listed.0 == 200 && listed.1["available"] as? Bool == true && listed.1["pageURL"] as? String == base + "/"
                     && apps.count == 1 && apps[0]["id"] as? String == "brane" && apps[0]["title"] as? String == "Brane Controller"
                     && builds.map { $0["build"] as? String } == ["2", "1"]
                     && builds[0]["installURL"] as? String == primary.installURL
                     && builds[0]["publishedAt"] is Double && builds[0]["hasIcon"] as? Bool == true
                     && builds[0]["profileKind"] as? String == "Ad Hoc" && builds[0]["size"] as? Int == 2_048,
                     "Builds API: \(listed)")
        let iconRoute = "/api/v1/home/builds/com.example.shared/1.0-2-20261015090000/icon"
        let icon = try await call(iconRoute)
        precondition(icon.0 == 200 && Data(base64Encoded: icon.1["data"] as? String ?? "") == png
                     && icon.1["mimeType"] as? String == "image/png")
        let anonymous = try await call("/api/v1/home/builds", authorized: false)
        let anonymousIcon = try await call(iconRoute, authorized: false)
        let posted = try await call("/api/v1/home/builds", method: "POST")
        let deleted = try await call("/api/v1/home/builds/com.example.shared/1.0-2-20261015090000", method: "DELETE")
        let unknownIcon = try await call("/api/v1/home/builds/com.example.shared/1.0-9-20261015090000/icon")
        let traversal = try await call("/api/v1/home/builds/com.example.shared/%2E%2E/icon")
        let shortRoute = try await call("/api/v1/home/builds/com.example.shared")
        precondition(anonymous.0 == 401 && anonymousIcon.0 == 401 && posted.0 == 405 && deleted.0 == 405
                     && unknownIcon.0 == 404 && traversal.0 == 404 && shortRoute.0 == 404,
                     "Builds are read-only and authenticated: \([anonymous.0, anonymousIcon.0, posted.0, deleted.0, unknownIcon.0, traversal.0, shortRoute.0])")
        precondition(FileManager.default.fileExists(atPath: pageRoot.appendingPathComponent(
            "apps/com.example.shared/1.0-2-20261015090000/app.ipa").path), "Nothing is removed through the API")

        AppSettings.shared.cantripHomeEnabled = false
        let disabled = try await call("/api/v1/home/builds")
        precondition(disabled.0 == 409, "Builds belong to Cantrip Home and follow its setting")
        print("Cantrip Home builds passed")
    }
}
