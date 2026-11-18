import Foundation

/// This Mac's recurring background jobs for Home's Upcoming list: the user's LaunchAgents that run
/// on a calendar (`StartCalendarInterval`) or every so often (`StartInterval`). CI runners and
/// Apple's and Homebrew's agents are left out. Pausing boots a job out of launchd and disables it;
/// resuming enables and loads it again. Its plist is never edited, moved or removed.
enum MacLaunchJobs {
    struct Job: Equatable {
        var label: String
        var path: String
        /// `StartCalendarInterval` entries (Minute, Hour, Day, Weekday, Month; a missing key is any).
        var calendar: [[String: Int]]
        /// `StartInterval`, in seconds.
        var interval: Int?
    }

    static let excludedPrefixes = ["actions.runner.", "com.apple.", "homebrew.mxcl."]

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
    }

    /// The job a plist describes, or nil when it isn't a recurring job this list shows.
    static func job(plist: [String: Any], path: String) -> Job? {
        guard let label = plist["Label"] as? String, !label.isEmpty,
              !excludedPrefixes.contains(where: { label.hasPrefix($0) }) else { return nil }
        func entry(_ value: Any) -> [String: Int]? {
            guard let dictionary = value as? [String: Any] else { return nil }
            var entry: [String: Int] = [:]
            for key in ["Minute", "Hour", "Day", "Weekday", "Month"] {
                if let number = dictionary[key] as? Int { entry[key] = number }
            }
            return entry
        }
        var calendar: [[String: Int]] = []
        if let value = plist["StartCalendarInterval"] {
            calendar = (value as? [Any])?.compactMap(entry) ?? entry(value).map { [$0] } ?? []
        }
        let interval = (plist["StartInterval"] as? Int).flatMap { $0 > 0 ? $0 : nil }
        guard !calendar.isEmpty || interval != nil else { return nil }
        return Job(label: label, path: path, calendar: calendar, interval: interval)
    }

    static func scan(folder: URL = folder) -> [Job] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder.resolvingSymlinksInPath(), includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "plist" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { return nil }
            return job(plist: plist, path: url.path)
        }.sorted { $0.label < $1.label }
    }

    // MARK: When

    /// The first time after `date` any of `entries` fires (launchd's rules: a missing key matches
    /// anything; Weekday 0 and 7 are Sunday; with both Day and Weekday, either one matches).
    static func nextRun(_ entries: [[String: Int]], after date: Date, calendar: Calendar = .current) -> Date? {
        entries.compactMap { nextRun($0, after: date, calendar: calendar) }.min()
    }

    static func nextRun(_ entry: [String: Int], after date: Date, calendar: Calendar = .current) -> Date? {
        let minutes = entry["Minute"].map { [$0] } ?? Array(0...59)
        let hours = entry["Hour"].map { [$0] } ?? Array(0...23)
        var day = calendar.startOfDay(for: date)
        for _ in 0..<800 {
            let parts = calendar.dateComponents([.month, .day, .weekday], from: day)
            let weekday = (parts.weekday ?? 1) - 1
            let monthMatches = entry["Month"].map { $0 == parts.month } ?? true
            let dayMatches: Bool
            switch (entry["Day"], entry["Weekday"]) {
            case let (day?, weekdayValue?): dayMatches = day == parts.day || weekdayValue % 7 == weekday
            case let (day?, nil): dayMatches = day == parts.day
            case let (nil, weekdayValue?): dayMatches = weekdayValue % 7 == weekday
            case (nil, nil): dayMatches = true
            }
            if monthMatches && dayMatches {
                for hour in hours {
                    for minute in minutes {
                        if let time = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day), time > date {
                            return time
                        }
                    }
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = next
        }
        return nil
    }

    /// "Daily at 3:00 AM", "Mondays at 9:30 AM", "Every hour at :15", "Every 15 minutes".
    static func scheduleText(_ job: Job) -> String {
        if job.calendar.isEmpty, let interval = job.interval { return every(seconds: interval) }
        let entries = job.calendar
        if entries.count == 1 { return describe(entries[0]) }
        let daily = entries.allSatisfy { Set($0.keys) == ["Hour", "Minute"] }
        if daily {
            let times = entries.sorted { ($0["Hour"]!, $0["Minute"]!) < ($1["Hour"]!, $1["Minute"]!) }
                .map { clock(hour: $0["Hour"]!, minute: $0["Minute"]!) }
            return times.count <= 3 ? "Daily at " + list(times) : "\(times.count) times a day"
        }
        return "\(entries.count) times on a schedule"
    }

    private static func describe(_ entry: [String: Int]) -> String {
        let time: String
        switch (entry["Hour"], entry["Minute"]) {
        case let (hour?, minute?): time = "at " + clock(hour: hour, minute: minute)
        case let (hour?, nil): time = "every minute from " + clock(hour: hour, minute: 0)
        case let (nil, minute?): time = String(format: "every hour at :%02d", minute)
        case (nil, nil): time = "every minute"
        }
        let weekdays = ["Sundays", "Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays"]
        if let weekday = entry["Weekday"], entry["Day"] == nil { return "\(weekdays[weekday % 7]) \(time)" }
        if let day = entry["Day"] {
            if let month = entry["Month"], (1...12).contains(month) {
                return "Every \(DateFormatter().monthSymbols[month - 1]) \(day) \(time)"
            }
            return "Monthly on day \(day) \(time)"
        }
        if entry["Hour"] != nil { return "Daily \(time)" }
        return time.prefix(1).uppercased() + time.dropFirst()
    }

    static func every(seconds: Int) -> String {
        switch seconds {
        case ..<60: return "Every \(seconds) seconds"
        case 60: return "Every minute"
        case ..<3_600 where seconds % 60 == 0: return "Every \(seconds / 60) minutes"
        case 3_600: return "Every hour"
        case ..<86_400 where seconds % 3_600 == 0: return "Every \(seconds / 3_600) hours"
        case 86_400: return "Every day"
        default: return seconds % 86_400 == 0 ? "Every \(seconds / 86_400) days" : "Every \(seconds / 60) minutes"
        }
    }

    static func clock(hour: Int, minute: Int) -> String {
        String(format: "%d:%02d %@", hour % 12 == 0 ? 12 : hour % 12, minute, hour < 12 ? "AM" : "PM")
    }

    private static func list(_ items: [String]) -> String {
        items.count <= 1 ? items.joined() : items.dropLast().joined(separator: ", ") + " and " + items.last!
    }

    // MARK: launchd

    /// Labels this user's launchd domain has disabled, from `launchctl print-disabled`.
    static func disabled(fromPrintDisabled text: String) -> Set<String> {
        var labels: Set<String> = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=>")
            guard parts.count == 2 else { continue }
            let state = parts[1].trimmingCharacters(in: .whitespaces)
            guard state == "disabled" || state == "true" else { continue }
            labels.insert(parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")))
        }
        return labels
    }

    /// Labels loaded in this user's launchd domain, from `launchctl list`.
    static func loaded(fromList text: String) -> Set<String> {
        Set(text.split(separator: "\n").dropFirst().compactMap { line in
            line.split(separator: "\t").last.map { $0.trimmingCharacters(in: .whitespaces) }
        })
    }

    struct State: Equatable {
        var disabled: Set<String>
        var loaded: Set<String>
    }

    static func currentState() -> State {
        State(disabled: disabled(fromPrintDisabled: launchctl(["print-disabled", domain]).output),
              loaded: loaded(fromList: launchctl(["list"]).output))
    }

    static var domain: String { "gui/\(getuid())" }

    /// Stops it and keeps launchd from loading it again until it's resumed. The plist stays.
    static func pause(_ job: Job) throws {
        _ = launchctl(["bootout", "\(domain)/\(job.label)"])
        let disable = launchctl(["disable", "\(domain)/\(job.label)"])
        guard disable.status == 0 else { throw Failure(message: "launchd didn't disable \(job.label): \(disable.output)") }
    }

    /// Allows it again and loads it from its plist.
    static func resume(_ job: Job) throws {
        let enable = launchctl(["enable", "\(domain)/\(job.label)"])
        guard enable.status == 0 else { throw Failure(message: "launchd didn't enable \(job.label): \(enable.output)") }
        let load = launchctl(["bootstrap", domain, job.path])
        // 5/37: already loaded.
        guard load.status == 0 || currentState().loaded.contains(job.label) else {
            throw Failure(message: "launchd didn't load \(job.label): \(load.output)")
        }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @discardableResult
    static func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
