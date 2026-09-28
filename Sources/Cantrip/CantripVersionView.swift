import AppKit
import SwiftUI

/// Settings section showing which Cantrip build is running, what the next
/// launch installs, and the latest version on GitHub.
struct CantripVersionView: View {
    @ObservedObject private var updater = UpdateChecker.shared
    /// Tabs streaming, queued, or running a shell command; restarting would cut them off.
    let busySessions: Int
    let onUpdate: (() -> Void)?
    @State private var restartError: String?

    var body: some View {
        CantripVersionContent(
            report: updater.versionReport, isChecking: updater.isChecking,
            busySessions: busySessions, restartError: restartError,
            onCheck: { updater.checkNow() }, onUpdate: onUpdate,
            onRestart: {
                do {
                    restartError = nil
                    try RemoteMaintenance.relaunch(Bundle.main.bundleURL)
                } catch {
                    restartError = error.localizedDescription
                }
            })
            .onAppear { updater.checkIfDue() }
    }
}

struct CantripVersionContent: View {
    let report: CantripVersionReport
    let isChecking: Bool
    let busySessions: Int
    var restartError: String?
    let onCheck: () -> Void
    let onUpdate: (() -> Void)?
    let onRestart: () -> Void

    var body: some View {
        let state = report.state(checking: isChecking)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Version").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if isChecking {
                    ProgressView().controlSize(.mini)
                } else {
                    Button(action: onCheck) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Check GitHub for the latest version")
                    .accessibilityLabel("Check for updates")
                }
            }
            versionRow("This build", report.running, date: report.runningDate)
            if let staged = report.staged {
                versionRow("Next launch", staged, date: report.stagedDate)
            }
            if let latest = report.latest {
                versionRow("Latest on GitHub", latest, date: report.latestDate, subject: report.latestSubject)
            }
            status(state, hasStagedBuild: report.staged != nil)
            if report.fetchFailed, report.latest != nil {
                Text("Couldn't reach GitHub, so this is the last version fetched.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let checkedAt = report.checkedAt {
                Text("Checked at \(checkedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if let restartError {
                Text(restartError).font(.caption2).foregroundStyle(.red)
            }
        }
    }

    private func versionRow(_ label: String, _ version: CantripBuildVersion, date: Date?,
                            subject: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(version.title)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
            }
            let details = [version.commit, version.hasLocalChanges ? "local changes" : nil,
                           date.map { $0.formatted(date: .abbreviated, time: .shortened) }]
                .compactMap { $0 }
            if !details.isEmpty {
                Text(details.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let subject {
                Text(subject)
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .textSelection(.enabled)
        .help(version.identity)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func status(_ state: CantripUpdateState, hasStagedBuild: Bool) -> some View {
        switch state {
        case .checking:
            statusLabel("Checking GitHub…", symbol: "clock", color: .secondary)
        case .upToDate(let unpushed):
            statusLabel(unpushed > 0
                        ? "Up to date, plus \(unpushed) commit\(unpushed == 1 ? "" : "s") not on GitHub yet"
                        : "Up to date",
                        symbol: "checkmark.circle.fill", color: .green)
            if hasStagedBuild { restartButton }
        case .staged:
            statusLabel("The latest version is ready. Restart Cantrip to install it.",
                        symbol: "arrow.down.circle.fill", color: .accentColor)
            restartButton
        case .available(let commits):
            statusLabel("\(commits) newer commit\(commits == 1 ? "" : "s") on GitHub",
                        symbol: "arrow.down.circle.fill", color: .accentColor)
            if let onUpdate {
                Button("Update and Restart", action: onUpdate)
                    .controlSize(.small)
                    .help("Pull from GitHub, rebuild, and relaunch Cantrip. Running replies are cut off.")
            }
        case .rebuildNeeded:
            statusLabel("The source checkout has changes this build doesn't include.",
                        symbol: "hammer.fill", color: .orange)
            if let onUpdate {
                Button("Rebuild and Restart", action: onUpdate)
                    .controlSize(.small)
                    .help("Rebuild from the source checkout and relaunch Cantrip. Running replies are cut off.")
            }
        case .unknown(let reason):
            statusLabel(reason, symbol: "questionmark.circle", color: .secondary)
        }
    }

    private func statusLabel(_ text: String, symbol: String, color: Color) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .font(.caption)
    }

    private var restartButton: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button("Restart to Install", action: onRestart)
                .controlSize(.small)
                .disabled(busySessions > 0)
            if busySessions > 0 {
                Text("Waiting for \(busySessions) running tab\(busySessions == 1 ? "" : "s") to finish.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
