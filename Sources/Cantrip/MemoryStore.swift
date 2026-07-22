import Foundation

/// Obsidian-style memory vault: a folder of markdown notes the CLI backends
/// read before acting and update after learning a working procedure.
final class MemoryStore {
    static let shared = MemoryStore()
    private init() {}

    /// Hermes-style caps: small enough to inject on every query, hard
    /// enough to force consolidation instead of endless appending.
    static let memoryCap = 2200
    static let userCap = 1375

    private var dirURL: URL { URL(fileURLWithPath: AppSettings.shared.memoryPath) }
    private var sessionsURL: URL { dirURL.appendingPathComponent("sessions") }

    func ensureVault() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dirURL.path) {
            try? fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
            Log.write("memory: vault created at \(dirURL.path)")
        }
        // Idempotently seed baseline notes (won't overwrite user edits).
        seed("imessage.md", Self.imessageSeed)
        seed("self.md", Self.selfSeed)
        seed("MEMORY.md", Self.memorySeed)
        seed("USER.md", Self.userSeed)
        seed("long-jobs.md", Self.longJobsSeed)
        seed("apple-data.md", Self.appleDataSeed)
        try? fm.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
    }

    /// Core memory (always injected): MEMORY.md + USER.md with cap status.
    func coreMemoryBlock() -> String {
        let memory = (try? String(contentsOf: dirURL.appendingPathComponent("MEMORY.md"),
                                  encoding: .utf8)) ?? "(empty)"
        let user = (try? String(contentsOf: dirURL.appendingPathComponent("USER.md"),
                                encoding: .utf8)) ?? "(empty)"
        var block = """
        MEMORY.md (environment & conventions — cap \(Self.memoryCap) chars, now \(memory.count)):
        \(memory)

        USER.md (model of the user — cap \(Self.userCap) chars, now \(user.count)):
        \(user)
        """
        if memory.count > Self.memoryCap || user.count > Self.userCap {
            block += "\n\nWARNING: a core memory file is over its cap. Consolidate it now (merge duplicates, drop stale entries) — do not just append."
        }
        return block
    }

    /// Session layer: append each completed exchange to a daily log the
    /// agent can grep (poor man's full-text session search).
    func logExchange(user: String, assistant: String, backend: String) {
        try? FileManager.default.createDirectory(at: sessionsURL,
                                                 withIntermediateDirectories: true)
        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter(); time.dateFormat = "HH:mm"
        let file = sessionsURL.appendingPathComponent("\(day.string(from: Date())).md")
        let entry = "\n## \(time.string(from: Date())) · \(backend)\n**User:** \(user)\n\n**Assistant:** \(assistant.prefix(3000))\n"
        guard let data = entry.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: file)
        }
    }

    private func seed(_ name: String, _ content: String) {
        let url = dirURL.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? content.write(to: url, atomically: true, encoding: .utf8)
        Log.write("memory: seeded \(name)")
    }

    private static let usageKey = "memoryNoteUsage"

    private func noteFiles() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: dirURL, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }
            .filter { !["MEMORY.md", "USER.md"].contains($0.lastPathComponent) }
    }

    /// Record that a note was surfaced by retrieval (recency/frequency).
    private func noteUsed(_ name: String) {
        var dict = UserDefaults.standard.dictionary(forKey: Self.usageKey)
            as? [String: [String: Any]] ?? [:]
        var entry = dict[name] ?? [:]
        entry["count"] = ((entry["count"] as? Int) ?? 0) + 1
        entry["last"] = Date().timeIntervalSince1970
        dict[name] = entry
        UserDefaults.standard.set(dict, forKey: Self.usageKey)
    }

    /// One-line index: recently-used notes first, stale ones flagged.
    func indexLine() -> String {
        let usage = UserDefaults.standard.dictionary(forKey: Self.usageKey)
            as? [String: [String: Any]] ?? [:]
        let files = noteFiles()
        guard !files.isEmpty else { return "none yet" }
        let now = Date().timeIntervalSince1970
        let sorted = files.sorted { a, b in
            let la = (usage[a.lastPathComponent]?["last"] as? Double) ?? 0
            let lb = (usage[b.lastPathComponent]?["last"] as? Double) ?? 0
            if la != lb { return la > lb }
            return a.lastPathComponent < b.lastPathComponent
        }
        return sorted.prefix(50).map { url in
            let name = url.lastPathComponent
            let firstLine = (try? String(contentsOf: url, encoding: .utf8))?
                .split(separator: "\n", omittingEmptySubsequences: true).first
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) } ?? nil
            var label = (firstLine?.isEmpty == false) ? "\(name) (\(firstLine!))" : name
            let lastUsed = (usage[name]?["last"] as? Double) ?? 0
            let mtime = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate]
                as? Date)?.timeIntervalSince1970 ?? 0
            if now - max(lastUsed, mtime) > 30 * 86400 { label += " [stale?]" }
            return label
        }.joined(separator: ", ")
    }

    // MARK: - Retrieval (keyword-based, app-side)

    static func terms(from query: String) -> [String] {
        ConversationContextBuilder.terms(from: query)
    }

    static func score(_ text: String, terms: [String]) -> Int {
        terms.reduce(0) { $0 + text.components(separatedBy: $1).count - 1 }
    }

    /// Find the most relevant note/session snippets for a query and
    /// return them ready for injection. Nil when nothing matches.
    func retrieve(for query: String, maxChars: Int = 2400) -> String? {
        let terms = Self.terms(from: query)
        guard !terms.isEmpty else { return nil }

        var candidates = noteFiles()
        let sessionFiles = ((try? FileManager.default.contentsOfDirectory(
            at: sessionsURL, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(14)
        candidates += sessionFiles

        var scored: [(name: String, score: Int, chunk: String, isNote: Bool)] = []
        for url in candidates {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let fileScore = Self.score(text.lowercased(), terms: terms)
            guard fileScore > 0 else { continue }
            let paragraphs = text.components(separatedBy: "\n\n")
            let best = paragraphs.max {
                Self.score($0.lowercased(), terms: terms) < Self.score($1.lowercased(), terms: terms)
            } ?? text
            scored.append((url.lastPathComponent, fileScore,
                           String(best.prefix(800)),
                           !url.path.contains("/sessions/")))
        }
        guard !scored.isEmpty else { return nil }
        scored.sort { $0.score > $1.score }

        var out = ""
        for hit in scored.prefix(3) {
            let entry = "— from \(hit.name):\n\(hit.chunk)\n"
            if out.count + entry.count > maxChars { break }
            out += entry
            if hit.isNote { noteUsed(hit.name) }
        }
        return out.isEmpty ? nil : out
    }

    /// Full note contents, capped — for backends without file access
    /// (local models get memory read-only, inlined into the prompt).
    func inlineDigest(cap: Int = 6000) -> String? {
        let files = ((try? FileManager.default.contentsOfDirectory(
            at: dirURL, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "md" }
        guard !files.isEmpty else { return nil }
        var out = ""
        for url in files {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let chunk = "--- \(url.lastPathComponent) ---\n\(text)\n"
            if out.count + chunk.count > cap { break }
            out += chunk
        }
        return out.isEmpty ? nil : out
    }

    private static let appleDataSeed = """
    # Reading iMessage history & Calendar

    ## iMessage (read) — requires Full Disk Access for Cantrip
    History is SQLite at `~/Library/Messages/chat.db`. Recent messages:
    ```sh
    sqlite3 ~/Library/Messages/chat.db "SELECT datetime(m.date/1000000000 + 978307200,'unixepoch','localtime') AS ts, h.id AS sender, m.is_from_me, COALESCE(m.text,'') FROM message m LEFT JOIN handle h ON m.handle_id=h.rowid ORDER BY m.date DESC LIMIT 30;"
    ```
    - `date` is Apple epoch nanoseconds (hence the +978307200 conversion).
    - On newer macOS, text is often NULL with content in the \
    `attributedBody` blob; fall back to \
    `hex(attributedBody)` extraction or filter `WHERE m.text IS NOT NULL`.
    - Group chats: join `chat_message_join` / `chat`.
    - If sqlite3 errors "unable to open database file": Full Disk Access \
    isn't granted → tell the user to add Cantrip in System \
    Settings → Privacy & Security → Full Disk Access, then relaunch it.
    - Sending is in imessage.md (AppleScript; works with Messages closed).

    ## Calendar
    Prefer `icalBuddy` if present (`brew install ical-buddy`):
    ```sh
    icalBuddy -f eventsToday+7        # next week's events
    ```
    Fallback AppleScript (first use triggers a one-time Automation prompt):
    ```sh
    osascript -e 'tell application "Calendar" to get summary of every event of calendar 1 whose start date > (current date) and start date < ((current date) + 7 * days)'
    ```
    Create events via AppleScript `make new event ... at end of events`.
    """

    private static let longJobsSeed = """
    # Long-running jobs (recordings, big downloads, anything > 10 min)

    NEVER hold a single tool call open for the whole job — tool timeouts \
    and the launcher's inactivity watchdog will kill it. Instead:

    1. Launch detached so it survives everything:
       `nohup yt-dlp <url> -o "~/Movies/%(title)s.%(ext)s" > /tmp/job-NAME.log 2>&1 & echo $!`
       Save the PID and log path. For livestream recordings add \
       `--live-from-start` if wanted.
    2. Reply IMMEDIATELY with: what's running, where output lands, the log \
    path, and how to check progress. The job keeps running even if the \
    launcher closes.
    3. To notify the user when done, chain a notifier:
       `nohup sh -c 'yt-dlp <url> ...; osascript -e "display notification \\"Recording finished\\" with title \\"Cantrip job\\""' > /tmp/job-NAME.log 2>&1 &`
    4. When later asked "is it done?": `pgrep -f yt-dlp` and `tail /tmp/job-NAME.log`.

    Works the same for ffmpeg captures, rsync, training runs, etc.
    """

    private static let memorySeed = """
    # MEMORY — environment & conventions

    Facts about this machine and how things are done here. Keep under \
    2200 chars total: consolidate ruthlessly, merge duplicates, drop stale \
    entries. Newest-learned conventions win.

    - macOS, primary tools: Claude Code CLI, GitHub Copilot CLI, local Hermes.
    - Generated images go to ~/.cache/Cantrip/ (see image-output.md).
    """

    private static let userSeed = """
    # USER — model of the user

    Who the user is and how they like things. Keep under 1375 chars: \
    consolidate, don't append forever. Learn their name, preferences, \
    and working style from conversations and record them here.

    - (Nothing learned yet.)
    """

    private static let selfSeed = """
    # Cantrip — self-maintenance (the launcher you are running inside)

    Queries reach you through Cantrip, a macOS Spotlight-style \
    launcher. When asked to fix, improve, or debug "this tool" / "yourself" \
    / "the launcher" / "cantrip", THIS is what's meant — not other apps.

    - Source code: `~/Coding/Cantrip` (Swift/SwiftUI, SwiftPM)
    - Rebuild + relaunch: `make -C ~/Coding/Cantrip run`
      WARNING: this kills the running app — the current response dies with \
      it. Say so first, finish your message, run it last.
    - Debug log: `~/Library/Logs/Cantrip.log` (tail after relaunch)
    - App settings: UserDefaults domain `com.brian.agentspotlight` \
      (`defaults read com.brian.agentspotlight`)
    - Memory vault: this folder. Screenshot/paste cache: `~/.cache/Cantrip/`

    ## Permissions (macOS TCC)
    - Signing uses the self-signed cert "AgentSpotlight Dev" so grants \
      persist across rebuilds. Verify: `codesign -dvv <app> | grep Authority` \
      — if it says adhoc, the cert is missing/untrusted and grants will reset.
    - Mic / speech / location prompt automatically on use. Screen Recording, \
      Accessibility, and Full Disk Access can ONLY be enabled by the user in \
      System Settings → Privacy & Security (app relaunch required after).
    - Grants stuck / silently denied (common after signature changes): \
      `tccutil reset All com.brian.agentspotlight`, relaunch app, re-trigger \
      the feature so it prompts fresh.
    - Automation prompts (Messages, etc.) appear on first AppleScript use, \
      attributed to Cantrip.

    Keep this note updated when you learn new fixes or the app changes.
    """

    private static let imessageSeed = """
      # Sending Messages reliably

      Always resolve the recipient's exact phone/email in Contacts, then use the \
      transport-aware helper. It opens a blank composer, waits for Messages to \
      classify the recipient as iMessage, RCS, or SMS, and fails without sending \
      if the live transport cannot be identified.

      ```sh
      ~/Coding/Cantrip/Scripts/messages-send "+15551234567" "MESSAGE"
      ~/Coding/Cantrip/Scripts/messages-send --detect "+15551234567"
    ```

    - Recipient: phone number with country code (e.g. +14085551234) or their \
      iCloud email.
    - To look up a number by name, query Contacts:
      `osascript -e 'tell application "Contacts" to get value of first phone of first person whose name contains "NAME"'`
      - The helper preserves the clipboard, supports Unicode, and verifies that \
      the draft cleared after sending. It never retries an uncertain send.
      - Do not force a phone number through the iMessage AppleScript service; \
      Android recipients need the resolved RCS/SMS composer.
    """
}
