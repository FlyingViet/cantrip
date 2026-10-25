import SwiftUI

/// Runs `StorageUpkeep` in the host about once a day: 10 minutes after launch, then whenever a
/// day has passed since the last cleanup (including one run with `cantrip cleanup`), and on
/// request from Settings. Work happens off the main thread, one cleanup at a time.
@MainActor
final class StorageUpkeepStatus: ObservableObject {
    static let shared = StorageUpkeepStatus()
    static let interval: TimeInterval = 24 * 60 * 60
    static let firstCheckDelay: TimeInterval = 10 * 60
    static let checkInterval: TimeInterval = 60 * 60

    @Published private(set) var lastReport: StorageUpkeep.Report?
    @Published private(set) var isRunning = false
    private var timer: Timer?
    private let stateDirectory = StorageUpkeep.Configuration.standard().stateDirectory

    private init() {
        lastReport = StorageUpkeep.lastReport(in: stateDirectory)
    }

    func start() {
        timer?.invalidate()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.firstCheckDelay) { [weak self] in
            self?.runIfDue()
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runIfDue() }
        }
    }

    func runIfDue(now: Date = Date()) {
        guard AppSettings.shared.storageUpkeepEnabled, !isRunning else { return }
        lastReport = StorageUpkeep.lastReport(in: stateDirectory) ?? lastReport
        // A few minutes' slack so an hourly check doesn't push the daily run an hour later each day.
        if let last = lastReport?.finishedAt, now.timeIntervalSince(last) < Self.interval - 10 * 60 { return }
        runNow()
    }

    func runNow() {
        guard !isRunning else { return }
        isRunning = true
        let configuration = StorageUpkeep.Configuration.standard()
        DispatchQueue.global(qos: .utility).async {
            let report = StorageUpkeep.perform(configuration, dryRun: false)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.isRunning = false
                    guard let report else {
                        Log.write("storage-upkeep: skipped, another cleanup is running")
                        return
                    }
                    self.lastReport = report
                    Log.write("storage-upkeep: \(report.summary) Kept \(report.keptSummary.joined(separator: "; ")). "
                        + report.worktreesKept.map { "Kept worktree \($0.path): \($0.reason ?? "")." }.joined(separator: " ")
                        + " Took \(Int(report.finishedAt.timeIntervalSince(report.startedAt))) s; "
                        + "details in \(StorageUpkeep.Configuration.standard().stateDirectory.path)/storage-upkeep.log")
                }
            }
        }
    }

    var statusText: String {
        if isRunning { return "Cleaning up…" }
        guard let report = lastReport else {
            return AppSettings.shared.storageUpkeepEnabled
                ? "The first cleanup runs 10 minutes after Cantrip starts."
                : "Not run yet."
        }
        let when = report.finishedAt.formatted(.relative(presentation: .named))
        var text = "Last cleanup \(when): \(report.summary)"
        if let free = report.freeBytesAfter { text += " \(StorageUpkeep.format(free)) free." }
        return text
    }
}

/// Settings: the daily cleanup switch, how long unused sessions stay, and the last result.
struct StorageUpkeepView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var status = StorageUpkeepStatus.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Clean up unused agent sessions and worktrees daily", isOn: $settings.storageUpkeepEnabled)
                .font(.caption)
                .toggleStyle(.checkbox)
                .help("Removes Copilot session folders nothing has used for the set number of days, and agent git "
                    + "worktrees (in session folders, ~/.cache/Cantrip or temporary folders) that are clean, unchanged "
                    + "for 3 days and whose commits are on a branch. Sessions of open or closed tabs, ones named in "
                    + "memory notes, ones in use and anything with uncommitted or unpushed work stay.")
            if settings.storageUpkeepEnabled {
                Stepper(value: $settings.storageSessionRetentionDays, in: StorageUpkeep.sessionRetentionDays) {
                    Text("Keep unused sessions for \(settings.storageSessionRetentionDays) days")
                        .font(.caption)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(status.statusText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(status.isRunning ? "Cleaning Up…" : "Clean Up Now") { status.runNow() }
                    .font(.caption)
                    .disabled(status.isRunning)
            }
        }
    }
}
