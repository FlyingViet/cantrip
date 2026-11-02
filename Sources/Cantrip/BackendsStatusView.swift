import AppKit
import SwiftUI

/// Settings > Backends: whether each agent CLI is installed and signed in, its account, limits
/// and last real run, with Check Now and Sign In. Remote clients show the same rows.
struct BackendsStatusView: View {
    @ObservedObject var monitor: BackendStatusMonitor
    @State private var message: String?

    init(monitor: BackendStatusMonitor? = nil) {
        self.monitor = monitor ?? .shared
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Backends").font(.caption.weight(.semibold))
                Spacer(minLength: 6)
                Button("Check Now") {
                    message = "Checking…"
                    monitor.check()
                }
                .font(.caption)
                .disabled(monitor.statuses.allSatisfy(\.checking))
                .accessibilityLabel("Check every backend now")
            }
            Text("Cantrip checks each agent CLI on launch, every 30 minutes and after a sign-in error. A signed-out backend is skipped and its backups run instead.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let message {
                Text(message).font(.caption2).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            ForEach(monitor.statuses) { status in
                BackendStatusRow(status: status, monitor: monitor) { message = $0 }
            }
        }
        .onChange(of: monitor.statuses.contains(where: \.checking)) { _, checking in
            if !checking, message == "Checking…" { message = nil }
        }
    }
}

/// One backend: its name and state, then what Cantrip knows about it. Narrow panes move the
/// state under the name, like MCP Servers' rows.
struct BackendStatusRow: View {
    let status: BackendStatus
    let monitor: BackendStatusMonitor
    let report: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    name
                    state
                    Spacer(minLength: 6)
                    actions
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        name
                        Spacer(minLength: 6)
                        actions
                    }
                    state
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(BackendStatusText.lines(status).enumerated()), id: \.offset) { _, line in
                    Text(line.text).foregroundStyle(line.warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .textSelection(.enabled)
                }
            }
            .font(.caption2)
            .fixedSize(horizontal: false, vertical: true)
            signIn
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(status.name): \(BackendStatusText.stateLabel(status))")
    }

    private var name: some View {
        Text(status.name).font(.caption.weight(.medium)).lineLimit(1)
    }

    private var state: some View {
        Text(BackendStatusText.stateLabel(status))
            .font(.caption2)
            .foregroundStyle(status.state == .signedOut || status.state == .outOfQuota ? Color.orange : Color.secondary)
            .fixedSize()
    }

    private var actions: some View {
        HStack(spacing: 6) {
            Button("Check Now") { monitor.check([backend]) }
                .disabled(status.checking)
                .accessibilityLabel("Check \(status.name) now")
            if status.signIn.code != nil {
                Button("Cancel") { monitor.cancelSignIn(backend) }
                    .accessibilityLabel("Cancel the \(status.name) sign-in")
            } else if BackendStatusText.offersSignIn(status) {
                // The row shows what to do next (the code, or where to finish).
                Button("Sign In…") { _ = monitor.signIn(backend) }
                    .accessibilityLabel("Sign in to \(status.name)")
            }
        }
        .font(.caption)
        .fixedSize()
    }

    @ViewBuilder private var signIn: some View {
        if let code = status.signIn.code {
            VStack(alignment: .leading, spacing: 4) {
                Text(status.signIn.message ?? "Open the link on any device and enter the code.")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(code).font(.title3.monospaced().weight(.semibold)).textSelection(.enabled)
                    .accessibilityLabel("Sign-in code \(code.map(String.init).joined(separator: " "))")
                HStack(spacing: 8) {
                    if let link = status.signIn.url.flatMap(URL.init(string:)) {
                        Button("Open Link") { NSWorkspace.shared.open(link) }
                            .accessibilityLabel("Open the \(status.name) sign-in page")
                    }
                    Button("Copy Code") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                        report("Code copied.")
                    }
                    .accessibilityLabel("Copy the \(status.name) sign-in code")
                }
                .font(.caption)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
        } else if let note = BackendStatusText.signInNote(status) {
            Text(note).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var backend: MonitoredBackend { MonitoredBackend(rawValue: status.id) ?? .copilot }
}

/// The words every client uses for a backend's status.
enum BackendStatusText {
    struct Line: Equatable {
        let text: String
        var warning = false
    }

    static func stateLabel(_ status: BackendStatus) -> String {
        if status.checking { return "Checking…" }
        let label: String
        switch status.state {
        case .ready: label = "Ready"
        case .signedOut: label = "Signed out"
        case .outOfQuota: label = "Out of quota"
        case .notInstalled: label = "Not installed"
        case .unknown: label = "Unknown"
        }
        return label
    }

    static func offersSignIn(_ status: BackendStatus) -> Bool {
        status.state != .notInstalled && (status.state == .signedOut || status.signedIn != true)
    }

    static func signInNote(_ status: BackendStatus) -> String? {
        if let message = status.signIn.message { return message }
        return status.signIn.mode == "terminal" && offersSignIn(status) ? status.signIn.hint : nil
    }

    static func lines(_ status: BackendStatus, now: Date = Date()) -> [Line] {
        var lines = [Line(text: status.summary)]
        if status.state == .notInstalled { lines.append(Line(text: "Install \(status.name) on the Mac to use it.")) }
        if let path = status.path {
            lines.append(Line(text: "Installed: \(path)" + (status.version.map { " · \($0)" } ?? "")))
        }
        let account = [status.account, status.authMethod, status.plan].compactMap { $0 }
        if !account.isEmpty { lines.append(Line(text: "Account: " + account.joined(separator: " · "))) }
        for quota in status.quota {
            let used = quota.usedPercent.map { String(format: "%.0f%% used", min(100, max(0, $0))) } ?? "usage unknown"
            lines.append(Line(text: "\(quota.name): \(used)" + (time(quota.resetsAt, now: now).map { " · resets \($0)" } ?? "")))
        }
        if let success = time(status.lastSuccessAt, now: now) { lines.append(Line(text: "Last successful run: \(success)")) }
        if let error = status.lastAuthError {
            lines.append(Line(text: "Last sign-in error: \(error.message)" + (time(error.at, now: now).map { " (\($0))" } ?? ""),
                              warning: true))
        }
        if status.state == .unknown, let problem = status.problem, problem != status.summary {
            lines.append(Line(text: problem, warning: true))
        }
        lines.append(Line(text: status.checking ? "Checking now…"
                          : time(status.checkedAt, now: now).map { "Checked \($0)" } ?? "Not checked yet"))
        return lines
    }

    static func time(_ iso: String?, now: Date = Date()) -> String? {
        guard let date = iso.flatMap({ ISODate.date(from: $0) }) else { return nil }
        let style: Date.FormatStyle = Calendar.current.isDate(date, inSameDayAs: now)
            ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day().hour().minute()
        return date.formatted(style)
    }
}
