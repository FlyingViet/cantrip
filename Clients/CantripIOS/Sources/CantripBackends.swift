import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// `GET/POST /api/v1/backends`: whether each agent CLI on the Mac (Copilot, Claude Code,
/// Antigravity, Codex) is installed and signed in, its account, limits and last real run. Never a
/// token. A signed-out backend is skipped by the Mac's routing until it's signed in again.
struct CantripBackendsSnapshot: Decodable, Equatable {
    var backends: [CantripBackendStatus]
    var checkInterval: Int?
    /// What a Sign In or Cancel did ("Finish signing in in Terminal on the Mac.").
    var message: String?
}

struct CantripBackendStatus: Decodable, Equatable, Identifiable {
    struct Quota: Decodable, Equatable {
        var name: String
        var usedPercent: Double?
        var resetsAt: String?
    }

    struct Event: Decodable, Equatable {
        var message: String
        var at: String
    }

    struct SignIn: Decodable, Equatable {
        /// `deviceCode` (a link and a code any device can finish) or `terminal` (only on the Mac).
        var mode: String
        var command: String
        var hint: String
        var url: String?
        var code: String?
        var startedAt: String?
        var message: String?
    }

    var id: String
    var name: String
    /// `ready`, `signedOut`, `outOfQuota`, `notInstalled` or `unknown`.
    var state: String
    var summary: String
    var path: String?
    var version: String?
    var signedIn: Bool?
    var account: String?
    var authMethod: String?
    var plan: String?
    var quota: [Quota]?
    var limitedUntil: String?
    var lastSuccessAt: String?
    var lastAuthError: Event?
    var checkedAt: String?
    var checking: Bool?
    var unavailable: Bool?
    var problem: String?
    var signIn: SignIn

    var isChecking: Bool { checking == true }
    var isSigningIn: Bool { signIn.code != nil }
}

/// The words every Cantrip client uses for a backend's status (Cantrip's own Settings says the same).
enum CantripBackendText {
    struct Line: Equatable, Hashable {
        var text: String
        var warning = false
    }

    static func stateLabel(_ status: CantripBackendStatus) -> String {
        if status.isChecking { return "Checking…" }
        let label: String
        switch status.state {
        case "ready": label = "Ready"
        case "signedOut": label = "Signed out"
        case "outOfQuota": label = "Out of quota"
        case "notInstalled": label = "Not installed"
        default: label = "Unknown"
        }
        return label
    }

    static func isProblem(_ status: CantripBackendStatus) -> Bool {
        status.state == "signedOut" || status.state == "outOfQuota"
    }

    static func offersSignIn(_ status: CantripBackendStatus) -> Bool {
        status.state != "notInstalled" && (status.state == "signedOut" || status.signedIn != true)
    }

    static func signInNote(_ status: CantripBackendStatus) -> String? {
        if let message = status.signIn.message { return message }
        return status.signIn.mode == "terminal" && offersSignIn(status) ? status.signIn.hint : nil
    }

    /// The row's one line under the state: who's signed in and the limit closest to full, or why not.
    static func brief(_ status: CantripBackendStatus) -> String {
        guard status.state == "ready" else { return status.summary }
        let top = (status.quota ?? []).max { ($0.usedPercent ?? 0) < ($1.usedPercent ?? 0) }
        let quota = top.flatMap { quota in quota.usedPercent.map { "\(quota.name) \(Int($0.rounded()))% used" } }
        let parts = [status.account ?? status.authMethod, status.plan, quota].compactMap { $0 }
        return parts.isEmpty ? status.summary : parts.joined(separator: " · ")
    }

    static func lines(_ status: CantripBackendStatus, now: Date = Date()) -> [Line] {
        var lines = [Line(text: status.summary)]
        if status.state == "notInstalled" { lines.append(Line(text: "Install \(status.name) on the Mac to use it.")) }
        if let path = status.path {
            lines.append(Line(text: "Installed: \(path)" + (status.version.map { " · \($0)" } ?? "")))
        }
        let account = [status.account, status.authMethod, status.plan].compactMap { $0 }
        if !account.isEmpty { lines.append(Line(text: "Account: " + account.joined(separator: " · "))) }
        for quota in status.quota ?? [] {
            let used = quota.usedPercent.map { "\(Int(min(100, max(0, $0)).rounded()))% used" } ?? "usage unknown"
            lines.append(Line(text: "\(quota.name): \(used)" + (time(quota.resetsAt, now: now).map { " · resets \($0)" } ?? "")))
        }
        if let success = time(status.lastSuccessAt, now: now) { lines.append(Line(text: "Last successful run: \(success)")) }
        if let error = status.lastAuthError {
            lines.append(Line(text: "Last sign-in error: \(error.message)" + (time(error.at, now: now).map { " (\($0))" } ?? ""),
                              warning: true))
        }
        if status.state == "unknown", let problem = status.problem, problem != status.summary {
            lines.append(Line(text: problem, warning: true))
        }
        lines.append(Line(text: status.isChecking ? "Checking now…"
                          : time(status.checkedAt, now: now).map { "Checked \($0)" } ?? "Not checked yet"))
        return lines
    }

    static func time(_ iso: String?, now: Date = Date()) -> String? {
        guard let iso else { return nil }
        let formatter = ISO8601DateFormatter()
        var date = formatter.date(from: iso)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            date = formatter.date(from: iso)
        }
        guard let date else { return nil }
        let style: Date.FormatStyle = Calendar.current.isDate(date, inSameDayAs: now)
            ? .dateTime.hour().minute() : .dateTime.month(.abbreviated).day().hour().minute()
        return date.formatted(style)
    }

    static let unsupported = "Update and reopen Cantrip on your Mac to see its backends."
}

/// The snapshot, kept current while a Backends screen is open: every 8 seconds, every 1.5
/// while a check or a sign-in is moving.
@MainActor
final class CantripBackendsStore: ObservableObject {
    @Published var snapshot: CantripBackendsSnapshot?
    @Published var error: String?
    @Published var message: String?
    @Published var working: String?
    let remote: CantripRemoteModel

    init(remote: CantripRemoteModel, snapshot: CantripBackendsSnapshot? = nil) {
        self.remote = remote
        self.snapshot = snapshot
    }

    func status(_ id: String) -> CantripBackendStatus? { snapshot?.backends.first { $0.id == id } }

    var isBusy: Bool { snapshot?.backends.contains { $0.isChecking || $0.isSigningIn } ?? false }

    func load() async {
        do {
            snapshot = try await remote.backends()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func poll() async {
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(for: .milliseconds(isBusy ? 1_500 : 8_000))
        }
    }

    /// Check now (one backend, or all with `id` nil), Sign In or Cancel.
    func act(_ action: String, id: String? = nil) {
        working = action
        if action == "check" { message = "Checking…" }
        Task {
            defer { working = nil }
            var body: [String: Any] = ["action": action]
            if let id { body["id"] = id }
            if let updated = await remote.backendsAction(body) {
                snapshot = updated
                error = nil
                // A sign-in's next step shows in its row (the code, or where to finish).
                message = action == "check" ? "Checking…" : nil
            } else {
                error = remote.errorMessage ?? "That didn't go through."
            }
            try? await Task.sleep(for: .milliseconds(800))
            await load()
            if message == "Checking…", !isBusy { message = nil }
        }
    }
}

/// Settings' Backends section (Tools & sign-ins): one row per backend CLI on the Mac.
struct CantripBackendsSection: View {
    @StateObject private var store: CantripBackendsStore

    init(remote: CantripRemoteModel, snapshot: CantripBackendsSnapshot? = nil) {
        _store = StateObject(wrappedValue: CantripBackendsStore(remote: remote, snapshot: snapshot))
    }

    var body: some View {
        Section {
            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            if let message = store.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            ForEach(store.snapshot?.backends ?? []) { status in
                #if os(macOS)
                CantripBackendRow(status: status, store: store)
                #else
                NavigationLink { CantripBackendDetail(id: status.id, store: store) } label: {
                    CantripBackendSummary(status: status, store: store)
                }
                .accessibilityIdentifier("backends.\(status.id)")
                #endif
            }
            if store.snapshot != nil {
                Button("Check All Now") { store.act("check") }
                    .disabled(store.working != nil)
                    .accessibilityLabel("Check every backend now")
                    .accessibilityIdentifier("backends.checkAll")
            }
            #if os(macOS)
            Text(Self.explanation).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            #endif
        } header: {
            Text("Backends")
        } footer: {
            #if os(iOS)
            Text(Self.explanation)
            #endif
        }
        .task { await store.poll() }
    }

    static let explanation = "Whether each agent CLI on your Mac is installed and signed in. Cantrip checks on launch, every 30 minutes and after a sign-in error; a signed-out backend is skipped and your backups run instead."
}

/// A whole sheet of backends, for the alert that one went signed out or came back.
struct CantripBackendsView: View {
    @ObservedObject var remote: CantripRemoteModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        CantripSheetStack(embedded: false) {
            List { CantripBackendsSection(remote: remote) }
                .navigationTitle("Backends")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
    }
}

/// iPhone's row: name, state and the line that matters; Sign In when it needs one.
struct CantripBackendSummary: View {
    let status: CantripBackendStatus
    @ObservedObject var store: CantripBackendsStore

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(status.name)
                Text(CantripBackendText.stateLabel(status)).font(.caption).foregroundStyle(stateColor(status))
                Text(CantripBackendText.brief(status)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if status.isSigningIn {
                Text(status.signIn.code ?? "").font(.callout.monospaced().weight(.semibold))
                    .accessibilityLabel("Sign-in code waiting")
            } else if CantripBackendText.offersSignIn(status) {
                Button("Sign In…") { store.act("signIn", id: status.id) }
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .disabled(store.working != nil)
                    .accessibilityLabel("Sign in to \(status.name)")
            }
        }
    }
}

/// One backend's page: everything Cantrip knows, Check Now and Sign In, and the device code.
struct CantripBackendDetail: View {
    let id: String
    @ObservedObject var store: CantripBackendsStore

    var body: some View {
        List {
            if let status = store.status(id) {
                Section {
                    ForEach(CantripBackendText.lines(status), id: \.self) { line in
                        Text(line.text).font(.subheadline)
                            .foregroundStyle(line.warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                            .textSelection(.enabled)
                    }
                } header: {
                    Text(CantripBackendText.stateLabel(status))
                }
                Section {
                    CantripBackendSignIn(status: status, store: store)
                    Button("Check Now") { store.act("check", id: id) }
                        .disabled(store.working != nil || status.isChecking)
                        .accessibilityLabel("Check \(status.name) now")
                }
            }
            if let message = store.message {
                Section { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
            if let error = store.error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
        }
        .navigationTitle(store.status(id)?.name ?? "Backend")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.poll() }
    }
}

/// Sign In, its device code (with the link and Copy), Cancel, or why it has to happen on the Mac.
struct CantripBackendSignIn: View {
    let status: CantripBackendStatus
    @ObservedObject var store: CantripBackendsStore
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let code = status.signIn.code {
            VStack(alignment: .leading, spacing: 8) {
                Text(status.signIn.message ?? "Open the link on any device and enter the code.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text(code).font(.title2.monospaced().weight(.semibold)).textSelection(.enabled)
                    .accessibilityLabel("Sign-in code \(code.map(String.init).joined(separator: " "))")
                HStack(spacing: 12) {
                    if let link = status.signIn.url.flatMap(URL.init(string:)) {
                        Button("Open Link") { openURL(link) }
                            .buttonStyle(.borderedProminent)
                            .accessibilityLabel("Open the \(status.name) sign-in page")
                    }
                    Button("Copy Code") { copy(code) }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Copy the \(status.name) sign-in code")
                    Spacer(minLength: 0)
                    Button("Cancel", role: .cancel) { store.act("cancelSignIn", id: status.id) }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Cancel the \(status.name) sign-in")
                }
            }
            .padding(.vertical, 4)
        } else {
            if CantripBackendText.offersSignIn(status) {
                Button("Sign In…") { store.act("signIn", id: status.id) }
                    .disabled(store.working != nil)
                    .accessibilityLabel("Sign in to \(status.name)")
                    .accessibilityIdentifier("backends.signIn.\(status.id)")
            }
            if let note = CantripBackendText.signInNote(status) {
                Text(note).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func copy(_ code: String) {
        #if os(iOS)
        UIPasteboard.general.string = code
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        #endif
        store.message = "Code copied."
    }
}

#if os(macOS)
/// Gateway Mac's row, as Cantrip's own Settings shows it: name, state and actions, then the details.
struct CantripBackendRow: View {
    let status: CantripBackendStatus
    @ObservedObject var store: CantripBackendsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(status.name).fontWeight(.medium)
                Text(CantripBackendText.stateLabel(status)).font(.caption).foregroundStyle(stateColor(status))
                Spacer(minLength: 8)
                Button("Check Now") { store.act("check", id: status.id) }
                    .disabled(store.working != nil || status.isChecking)
                    .accessibilityLabel("Check \(status.name) now")
                    .fixedSize()
            }
            VStack(alignment: .leading, spacing: 1) {
                ForEach(CantripBackendText.lines(status), id: \.self) { line in
                    Text(line.text).foregroundStyle(line.warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .textSelection(.enabled)
                }
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            CantripBackendSignIn(status: status, store: store)
                .font(.caption)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(status.name): \(CantripBackendText.stateLabel(status))")
    }
}
#endif

private func stateColor(_ status: CantripBackendStatus) -> Color {
    if status.isChecking { return .secondary }
    if CantripBackendText.isProblem(status) { return .orange }
    return .secondary
}
