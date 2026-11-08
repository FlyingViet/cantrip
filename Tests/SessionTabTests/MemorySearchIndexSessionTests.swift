import Foundation

extension SessionTabTests {
    /// The opt-in memory search index through MemoryStore: off keeps keyword retrieval exactly as
    /// before, on ranks chunks with the index, and an index that can't open falls back to keywords.
    @MainActor
    static func testMemorySearchIndexRetrieval() async throws {
        let settings = AppSettings.shared
        precondition(settings.memorySearchIndex == false, "the search index is off by default")
        for local in [true, false] {
            let pages = SettingsManifest.manifest(local: local)["pages"] as? [[String: Any]] ?? []
            let memoryFields = pages.first { $0["id"] as? String == "memory" }
                .flatMap { ($0["sections"] as? [[String: Any]])?.first?["fields"] as? [[String: Any]] } ?? []
            let field = memoryFields.first { $0["key"] as? String == "memorySearchIndex" }
            precondition(field?["type"] as? String == "toggle"
                         && (field?["visibleWhen"] as? [String: Any])?["key"] as? String == "memoryEnabled",
                         "every client gets the setting, shown while Memory vault is on: \(String(describing: field))")
        }

        let vault = FileManager.default.temporaryDirectory
            .appendingPathComponent("cantrip-memory-search-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vault.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: vault) }
        try """
        # Deploy waiter

        If the deploy waiter gives up after eight hours of busy tabs, restart the waiter with the staged build's version.
        """.write(to: vault.appendingPathComponent("deploy-waiter.md"), atomically: true, encoding: .utf8)
        var bulk = "# Weekly notes\n"
        for week in 0..<80 {
            bulk += "\n## Week \(week)\n"
            for topic in ["pipeline", "dashboard", "schedule", "checklist", "rollback"] {
                bulk += "- Reviewed the deploy \(topic) for week \(week) and the deploy plan for \(topic)s.\n"
            }
        }
        try bulk.write(to: vault.appendingPathComponent("weekly-notes.md"), atomically: true, encoding: .utf8)
        let query = "How do I restart the deploy waiter when it gives up?"
        try FileManager.default.createDirectory(at: vault.appendingPathComponent("archive"), withIntermediateDirectories: true)
        try "# Deploy waiter (history)\n\nThe first waiter version polled every five minutes and logged to the console.\n"
            .write(to: vault.appendingPathComponent("archive/deploy-waiter-history.md"), atomically: true, encoding: .utf8)
        let archiveQuery = "How often did the first waiter version poll?"

        func retrieved(_ searchIndex: Bool) async -> String {
            await MemoryStore.contextBlock(query: query, path: vault.path, isPrivate: true, isLocal: false,
                                           searchIndex: searchIndex)
        }
        func firstSource(_ block: String) -> String? {
            block.components(separatedBy: "\n").first { $0.hasPrefix("— from ") }
        }

        let keyword = await retrieved(false)
        let archiveOff = await MemoryStore.contextBlock(query: archiveQuery, path: vault.path, isPrivate: true,
                                                        isLocal: false, searchIndex: false)
        precondition(!archiveOff.contains("polled every five minutes"), "off: archive/ isn't searched: \(archiveOff)")
        precondition(firstSource(keyword) == "— from weekly-notes.md:", "off: keyword counting as before: \(keyword)")
        precondition(!FileManager.default.fileExists(atPath: MemorySearchIndex.defaultURL.path), "off: no index is made")

        let indexed = await retrieved(true)
        precondition(firstSource(indexed) == "— from deploy-waiter.md:"
                     && indexed.contains("restart the waiter with the staged build"), "on: the index picks the note: \(indexed)")
        precondition(FileManager.default.fileExists(atPath: MemorySearchIndex.defaultURL.path),
                     "the index lives in Application Support, outside the vault")
        let archiveOn = await MemoryStore.contextBlock(query: archiveQuery, path: vault.path, isPrivate: true,
                                                       isLocal: false, searchIndex: true)
        precondition(firstSource(archiveOn) == "— from archive/deploy-waiter-history.md:"
                     && archiveOn.contains("polled every five minutes"), "on: archive/ is searched, by path: \(archiveOn)")
        for block in [indexed, archiveOn] {
            let marker = "(verify before relying on them):\n"
            let snippets = block.components(separatedBy: marker).last?.components(separatedBy: "\n\nPRIVATE MODE").first ?? ""
            precondition(block.contains(marker) && snippets.count <= 2_400
                         && snippets.components(separatedBy: "— from ").count - 1 <= 3,
                         "the per-message budget is unchanged: \(snippets.count) chars")
        }
        let vaultFiles = try FileManager.default.contentsOfDirectory(atPath: vault.path).sorted()
        precondition(vaultFiles == ["archive", "deploy-waiter.md", "sessions", "weekly-notes.md"],
                     "the vault is untouched: \(vaultFiles)")

        // A message deleted from a session log leaves the index right away.
        try "## 09:00 · Backend\n**User:** Where is the lighthouse key kept?\n\n**Assistant:** In the blue drawer.\n"
            .write(to: vault.appendingPathComponent("sessions/2026-01-05.md"), atomically: true, encoding: .utf8)
        let beforeDelete = await MemoryStore.contextBlock(query: "lighthouse key", path: vault.path, isPrivate: true,
                                                          isLocal: false, searchIndex: true)
        precondition(beforeDelete.contains("blue drawer"), "a new session entry is found: \(beforeDelete)")
        try "".write(to: vault.appendingPathComponent("sessions/2026-01-05.md"), atomically: true, encoding: .utf8)
        MemoryStore.searchIndexFilesChanged(path: vault.path)
        let afterDelete = await MemoryStore.contextBlock(query: "lighthouse key", path: vault.path, isPrivate: true,
                                                         isLocal: false, searchIndex: true)
        precondition(!afterDelete.contains("blue drawer"), "deleted text is gone from the index: \(afterDelete)")

        // Turning it off deletes the index; one that can't open falls back to keywords.
        MemoryStore.removeSearchIndex()
        _ = await retrieved(false)
        precondition(!FileManager.default.fileExists(atPath: MemorySearchIndex.defaultURL.path), "off deletes the index")
        try FileManager.default.createDirectory(at: MemorySearchIndex.defaultURL, withIntermediateDirectories: true)
        let fallback = await retrieved(true)
        precondition(fallback == keyword, "an index that can't open falls back to keyword retrieval: \(fallback)")
        MemoryStore.removeSearchIndex()
        _ = await retrieved(false)
        precondition(!FileManager.default.fileExists(atPath: MemorySearchIndex.defaultURL.path))
        print("Memory search index: off unchanged, on ranks chunks, deletion, removal and fallback passed")
    }
}
