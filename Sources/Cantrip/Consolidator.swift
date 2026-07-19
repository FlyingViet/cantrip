import Foundation

/// Background memory consolidation (Hermes-style reflection): at most once
/// a day, a cheap headless Claude Code run distills recent session logs
/// into MEMORY.md / USER.md / procedure notes and prunes stale content.
enum Consolidator {
    static func runIfDue() {
        let defaults = UserDefaults.standard
        let settings = AppSettings.shared
        guard settings.memoryEnabled else { return }
        let last = defaults.object(forKey: "lastConsolidation") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 20 * 3600 else { return }
        guard let claude = ClaudeCodeBackend.findClaude(configured: settings.claudePath) else {
            Log.write("consolidator: claude CLI not found, skipping")
            return
        }
        MemoryStore.shared.ensureVault()
        defaults.set(Date(), forKey: "lastConsolidation")

        let vault = settings.memoryPath
        let prompt = """
        You are Cantrip's background memory consolidator. Working \
        directory is the memory vault (\(vault)). Do the following, then \
        reply with ONE line summarizing what changed:
        1. Read sessions/*.md logs from the last 3 days (skip if none).
        2. Update MEMORY.md (environment/conventions, HARD CAP \(MemoryStore.memoryCap) \
        chars) and USER.md (user model, HARD CAP \(MemoryStore.userCap) chars): add \
        durable facts learned in sessions but not yet saved; merge duplicates; \
        drop stale entries. Consolidate — never exceed the caps.
        3. Review the other *.md procedure notes: merge overlapping ones and \
        update any contradicted by newer sessions. Notes marked [stale?] in \
        past prompts deserve scrutiny.
        4. Delete sessions/ files older than 30 days.
        """

        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: claude)
            let mode = settings.allowActions ? "bypassPermissions" : "acceptEdits"
            p.arguments = ["-p", prompt, "--model", "haiku", "--permission-mode", mode]
            p.currentDirectoryURL = URL(fileURLWithPath: vault)
            p.standardInput = FileHandle.nullDevice
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
            p.environment = env
            do {
                try p.run()
            } catch {
                Log.write("consolidator: launch failed: \(error.localizedDescription)")
                return
            }
            Log.write("consolidator: started (pid \(p.processIdentifier))")
            p.waitUntilExit()
            let summary = String(data: out.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Log.write("consolidator: exit \(p.terminationStatus) — \(summary.prefix(300))")
        }
    }
}
