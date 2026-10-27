import Foundation

/// Fetches upcoming events from Calendar.app via AppleScript and exposes
/// them as a context block. First run triggers the one-time macOS
/// Automation prompt for Calendar. Cached; fetched off the main thread.
final class CalendarProvider: ObservableObject {
    static let shared = CalendarProvider()
    @Published private(set) var contextLine: String?
    private var lastFetch: Date?
    private var fetching = false
    private init() {}

    private static let script = """
    set output to ""
    set startDate to current date
    set endDate to startDate + (2 * days)
    tell application "Calendar"
        repeat with cal in calendars
            try
                set evs to (every event of cal whose start date ≥ startDate and start date ≤ endDate)
                repeat with ev in evs
                    set evStart to start date of ev
                    set output to output & (short date string of evStart) & " " & (time string of evStart) & " — " & (summary of ev) & " [" & (name of cal) & "]" & linefeed
                end repeat
            end try
        end repeat
    end tell
    return output
    """

    /// Refresh at most every 15 minutes. Safe to call on every panel show.
    func refresh() {
        guard AppSettings.shared.shareCalendar else { return }
        if let lastFetch, Date().timeIntervalSince(lastFetch) < 900, contextLine != nil { return }
        guard !fetching else { return }
        fetching = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { self?.fetching = false }
            let result: ProcessRunner.Result
            do {
                result = try ProcessRunner.run("/usr/bin/osascript", ["-e", Self.script])
            } catch {
                Log.write("calendar: osascript launch failed: \(error.localizedDescription)")
                return
            }
            let text = result.text
            if result.status != 0 {
                Log.write("calendar: fetch failed (\(result.status)) \(result.errorText.prefix(120))")
                return
            }
            DispatchQueue.main.async {
                self?.lastFetch = Date()
                self?.contextLine = text.isEmpty ? "no events in the next 48 hours" : text
                Log.write("calendar: fetched \(text.isEmpty ? 0 : text.components(separatedBy: "\n").count) events")
            }
        }
    }
}
