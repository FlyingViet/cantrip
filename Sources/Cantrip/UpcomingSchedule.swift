import Foundation

// MARK: - Upcoming (docs/cantrip-home.md "Upcoming")

/// A one-off future step a tab or Home set up with `cantrip schedule add`: at `runAt` Cantrip
/// queues `message` in the tab that set it up, so nothing has to sleep in the background.
struct ScheduledStep: Codable, Equatable, Identifiable {
    enum Status: String, Codable {
        case scheduled
        case delivered
        case cancelled
        /// Its tab was closed before it was due.
        case failed
    }

    var id = UUID()
    /// What it will do, in plain words ("Compare tonight's code-mode runs with last night's").
    var title: String
    /// What the tab receives when it's due.
    var message: String
    /// The tab that set it up, which gets the message.
    var tabID: UUID
    var runAt: Date
    /// Waits past `runAt` until Home has no background runs, up to `deadline`, then goes anyway
    /// with a note.
    var whenHomeIsQuiet = false
    var deadline: Date?
    var createdAt = Date()
    var status: Status = .scheduled
    var finishedAt: Date?
}

/// A background wait a tab started through Cantrip (`cantrip schedule wait`) or registered by
/// process ID: listed while its process runs; cancelling stops it.
struct RegisteredWait: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String
    /// What it's waiting for ("Waits until the MacBook answers, then checks its build").
    var detail: String?
    var pid: Int32
    /// The process's start time, so a reused process ID is never mistaken for it.
    var processStart: Double
    /// Whether Cantrip started it in its own process group (cancelling stops the whole group).
    var ownGroup = false
    var tabID: UUID?
    /// When it gives up on its own, if it says.
    var until: Date?
    var createdAt = Date()
}

/// Plain-language words for a recurring Mac job, set with `cantrip schedule describe`.
struct MacJobNote: Codable, Equatable {
    var title: String
    var detail: String?
}

struct UpcomingRecords: Codable, Equatable {
    var steps: [ScheduledStep] = []
    var waits: [RegisteredWait] = []
    var macJobs: [String: MacJobNote] = [:]
}

/// `~/.cache/Cantrip/home/upcoming.json` (0600, in Home's 0700 folder). Finished steps are kept a
/// day for the record.
struct UpcomingStore {
    let url: URL

    static var standard: UpcomingStore {
        UpcomingStore(url: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/Cantrip/home/upcoming.json"))
    }

    func load() -> UpcomingRecords {
        guard let data = try? Data(contentsOf: url) else { return UpcomingRecords() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode(UpcomingRecords.self, from: data)) ?? UpcomingRecords()
    }

    func save(_ records: UpcomingRecords, now: Date = Date()) throws {
        var kept = records
        kept.steps.removeAll { $0.status != .scheduled && ($0.finishedAt ?? now) < now.addingTimeInterval(-86_400) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try encoder.encode(kept).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// When a scheduled step should run: "22:35" (today, or tomorrow once it's past), "2026-11-18 22:35",
/// an ISO 8601 date, or "+90m" / "+2h" / "+1d" from now.
enum UpcomingTime {
    static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let value = text.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("+"), let unit = value.last, let amount = Double(value.dropFirst().dropLast()), amount > 0 {
            let seconds: Double? = ["m": 60, "h": 3_600, "d": 86_400][String(unit)]
            return seconds.map { now.addingTimeInterval(amount * $0) }
        }
        let parts = value.split(separator: ":")
        if parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]), !value.contains(" "), !value.contains("-"),
           (0...23).contains(hour), (0...59).contains(minute),
           let today = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) {
            return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
        }
        for format in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        let iso = ISO8601DateFormatter()
        return iso.date(from: value)
    }
}

/// Plain-language names for things Cantrip didn't name: a script a tab left running, a Mac job's label.
enum UpcomingNames {
    /// "watch-first-run" -> "Watch first run".
    static func humanize(_ word: String) -> String {
        let spaced = word.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .split(separator: " ").joined(separator: " ")
        guard let first = spaced.first else { return word }
        return first.uppercased() + spaced.dropFirst()
    }

    static let interpreters: Set<String> = [
        "bash", "sh", "zsh", "dash", "env", "python", "python3", "Python", "node", "ruby", "perl", "nohup",
        "osascript", "caffeinate", "exec", "uv", "npx", "swift", "xcrun", "nice", "time", "command", "cd", "sleep",
        "timeout", "export",
    ]

    /// A job's name from its command line: the script it runs ("…/watch-first-run.py --x" ->
    /// "Watch first run"), else its program. Arguments never show.
    static func commandTitle(_ arguments: String) -> String? {
        var words = arguments.split(separator: " ").map(String.init)
        // `bash -c "python3 script.py > log"`: the command after -c.
        if let flag = words.firstIndex(of: "-c") { words = Array(words[(flag + 1)...]) }
        for word in words {
            let name = (word as NSString).lastPathComponent
            if word.hasPrefix("-") || interpreters.contains(name) || name.hasPrefix("python3.") || word.contains("=")
                || Double(word) != nil || ["&&", ";", "||", "&"].contains(word) { continue }
            if [">", ">>", "|", "2>&1", "<"].contains(word) || word.hasPrefix(">") { break }
            let stem = (name as NSString).deletingPathExtension
            return stem.isEmpty ? nil : humanize(stem)
        }
        return nil
    }

    /// A LaunchAgent's label as words: "com.example.nightly-sync" -> "Example · Nightly sync"; the
    /// account's own name in a label is left out ("com.<user>.flight-status" -> "Flight status").
    static func macJobTitle(label: String, ownNames: Set<String>) -> String {
        var parts = label.split(separator: ".").map(String.init)
        if parts.count >= 3, ["com", "org", "net", "io", "dev", "app", "local", "me", "co"].contains(parts[0].lowercased()) {
            parts.removeFirst()
        }
        guard parts.count >= 2 else { return humanize(label) }
        let owner = parts.removeFirst()
        let job = humanize(parts.joined(separator: " "))
        return ownNames.contains(owner.lowercased()) ? job : "\(humanize(owner)) · \(job)"
    }
}

/// Background jobs a tab's Copilot shell started (`detach`) that nobody registered.
enum UpcomingJobs {
    static let wrapperMarker = "__copilot_pid_path="

    /// Each job wrapper's command, skipping the wrappers themselves and jobs already listed as a
    /// registered wait, whether the wait names the job or its wrapper.
    static func unregistered(in rows: [Int32: MachineJobs.ProcessRow], registered: Set<Int32>,
                             uid: UInt32) -> [MachineJobs.ProcessRow] {
        let wrappers = Set(rows.values.filter { $0.arguments.contains(wrapperMarker) }.map(\.pid))
        return rows.values.filter {
            wrappers.contains($0.ppid) && !$0.arguments.contains(wrapperMarker) && $0.uid == uid
                && !registered.contains($0.pid) && !registered.contains($0.ppid)
        }.sorted { $0.pid < $1.pid }
    }
}
