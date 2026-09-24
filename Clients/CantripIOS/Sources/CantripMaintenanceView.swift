import SwiftUI

enum CantripMaintenanceAction: String, Codable, CaseIterable, Identifiable {
    case check, update, rebuild, restart
    var id: String { rawValue }
    var title: String {
        switch self {
        case .check: return "Check for Updates"
        case .update: return "Update & Rebuild"
        case .rebuild: return "Rebuild Current Source"
        case .restart: return "Restart Cantrip"
        }
    }
    var detail: String {
        switch self {
        case .check: return "Fetch the latest origin/main commits without changing source or restarting."
        case .update: return "Fast-forward the Mac's clean main branch, then build and sign Cantrip. Local edits are never stashed or discarded. Restart separately to activate the new build."
        case .rebuild: return "Build and sign the source currently on the Mac, including local edits, without pulling updates. Restart separately to activate it."
        case .restart: return "Briefly disconnect all remote clients and reopen Cantrip. The Mac will refuse if any tab, queue, or shell command is busy."
        }
    }
}

struct CantripMaintenanceRequest: Codable, Equatable {
    let id: UUID
    let action: CantripMaintenanceAction
    let revision: UUID
}

struct CantripMaintenanceSnapshot: Decodable {
    let revision: UUID
    struct Job: Decodable {
        let request: CantripMaintenanceRequest
        let phase: String
        let message: String
        let output: String
        let startedAt: Double
        let finishedAt: Double?
        var isRunning: Bool { finishedAt == nil }
    }
    let available: Bool
    let unavailableReason: String?
    let runningBuild: String
    let installedBuild: String?
    let busySessions: Int
    let branch: String?
    let localChanges: Bool?
    let commitsBehind: Int?
    let checkedAt: Double?
    let job: Job?
    let acceptedRequestIDs: [UUID]
}

@MainActor
final class CantripMaintenanceModel: ObservableObject {
    @Published private(set) var snapshot: CantripMaintenanceSnapshot?
    @Published private(set) var error: String?
    @Published private(set) var isRequesting = false
    @Published private(set) var pending: CantripMaintenanceRequest?
    private let defaults: UserDefaults
    private let pendingKey: String

    init(serverID: UUID?, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        pendingKey = "cantrip.maintenance.pending.\(serverID?.uuidString ?? "unconfigured")"
        if let data = defaults.data(forKey: pendingKey) {
            do { pending = try JSONDecoder().decode(CantripMaintenanceRequest.self, from: data) }
            catch { self.error = "Could not recover the previous maintenance request. \(error.localizedDescription)" }
        }
    }

    func refresh(fetch: () async throws -> CantripMaintenanceSnapshot) async {
        guard !isRequesting else { return }
        isRequesting = true
        defer { isRequesting = false }
        do {
            let value = try await fetch()
            try Task.checkCancellation()
            apply(value)
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    func submit(_ action: CantripMaintenanceAction,
                send: (CantripMaintenanceRequest) async throws -> CantripMaintenanceSnapshot) async {
        guard !isRequesting else { return }
        guard pending == nil || pending?.action == action else {
            error = "Refresh or retry the pending request before starting another action."
            return
        }
        isRequesting = true
        defer { isRequesting = false }
        do {
            guard let revision = pending?.revision ?? snapshot?.revision else {
                throw CantripRemoteError.notSent("Refresh the Mac's maintenance status first.")
            }
            let request = pending ?? CantripMaintenanceRequest(id: UUID(), action: action, revision: revision)
            defaults.set(try JSONEncoder().encode(request), forKey: pendingKey)
            pending = request
            let value = try await send(request)
            try Task.checkCancellation()
            apply(value)
            error = nil
        } catch is CancellationError {
            // Keep the ID: cancellation of a phone request does not cancel Mac work.
            return
        } catch {
            switch error {
            case CantripRemoteError.notSent, CantripRemoteError.authentication,
                 CantripRemoteError.maintenanceUnsupported:
                clearPending()
            case CantripRemoteError.http(let status, _) where (400..<500).contains(status):
                clearPending()
            default:
                break
            }
            self.error = error.localizedDescription
        }
    }

    private func apply(_ value: CantripMaintenanceSnapshot) {
        snapshot = value
        if let pending, value.acceptedRequestIDs.contains(pending.id) { clearPending() }
    }

    private func clearPending() {
        pending = nil
        defaults.removeObject(forKey: pendingKey)
    }

    func canStart(_ action: CantripMaintenanceAction) -> Bool {
        guard !isRequesting, pending == nil, error == nil,
              let snapshot, snapshot.available, snapshot.job?.isRunning != true else { return false }
        if action == .update && (snapshot.localChanges == true || snapshot.branch.map { $0 != "main" } == true) { return false }
        if action == .restart && snapshot.installedBuild == nil { return false }
        return action == .check || snapshot.busySessions == 0
    }
}

struct CantripMaintenanceView: View {
    @ObservedObject var remote: CantripRemoteModel
    var body: some View {
        CantripMaintenanceContent(remote: remote, serverID: remote.selectedServerID)
            .id(remote.usageIdentity)
    }
}

private struct CantripMaintenanceContent: View {
    @ObservedObject var remote: CantripRemoteModel
    @StateObject private var model: CantripMaintenanceModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirming: CantripMaintenanceAction?
    @State private var showConfirmation = false

    init(remote: CantripRemoteModel, serverID: UUID?) {
        self.remote = remote
        _model = StateObject(wrappedValue: CantripMaintenanceModel(serverID: serverID))
    }

    var body: some View {
        Form {
            Section("Connected Mac") {
                Text(remote.endpointHost)
                if let snapshot = model.snapshot {
                    LabeledContent("Running build", value: snapshot.runningBuild)
                    if let installed = snapshot.installedBuild {
                        LabeledContent("Installed build", value: installed)
                        if installed != snapshot.runningBuild {
                            Text("A different build is installed. Restart to activate it.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let branch = snapshot.branch { LabeledContent("Branch", value: branch.isEmpty ? "Detached HEAD" : branch) }
                    if let count = snapshot.commitsBehind { LabeledContent("Newer commits", value: String(count)) }
                    if let date = snapshot.checkedAt {
                        LabeledContent("Last checked") { Text(Date(timeIntervalSinceReferenceDate: date), style: .relative) }
                    }
                    if snapshot.localChanges == true {
                        Label("Local changes on the Mac. Update is blocked; rebuilding keeps those edits.",
                              systemImage: "pencil")
                    }
                    if snapshot.busySessions > 0 {
                        Label("\(snapshot.busySessions) busy Mac tab(s). Builds and restart require idle tabs.",
                              systemImage: "hourglass")
                    }
                    if let reason = snapshot.unavailableReason {
                        Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
            }
            Section {
                ForEach(CantripMaintenanceAction.allCases) { action in
                    Button(action.title) {
                        if action == .check {
                            Task { await submit(action) }
                        } else {
                            confirming = action
                            showConfirmation = true
                        }
                    }
                    .disabled(!model.canStart(action) || remote.isMutating || remote.isUploadingVideo)
                }
            } footer: {
                Text("Operations run on this Mac, even if you close AgentGateway. Building never automatically restarts Cantrip or stops a tab. This does not update the iPhone app.")
            }
            if let job = model.snapshot?.job {
                Section("Latest operation") {
                    if job.isRunning { ProgressView(job.message) }
                    else {
                        Label(job.message, systemImage: job.phase == "failed" ? "exclamationmark.triangle" : "checkmark.circle")
                            .foregroundStyle(job.phase == "failed" ? Color.orange : Color.primary)
                    }
                    if !job.output.isEmpty {
                        DisclosureGroup("Build output (latest)") {
                            Text(job.output).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
            }
            Section {
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    if model.snapshot != nil { Text("Showing the last received status.").font(.caption).foregroundStyle(.secondary) }
                }
                if let pending = model.pending {
                    Text("The Mac may have accepted \(pending.action.title). Refresh to recover its status, or retry the same request safely.")
                        .font(.caption)
                    Button("Retry Pending Request") { Task { await submit(pending.action) } }
                        .disabled(model.isRequesting)
                }
                Button("Refresh Status") { Task { await refresh() } }.disabled(model.isRequesting)
                if model.isRequesting { ProgressView("Contacting Mac...") }
            }
        }
        .navigationTitle("Update Cantrip")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(confirming?.title ?? "Cantrip", isPresented: $showConfirmation, titleVisibility: .visible) {
            if let confirming {
                Button(confirming.title, role: confirming == .restart ? .destructive : nil) {
                    Task { await submit(confirming) }
                }
            }
        } message: {
            Text(confirming?.detail ?? "")
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(model.snapshot?.job?.isRunning == true || model.pending != nil ? 3 : 15)) }
                catch { return }
            }
        }
        .refreshable { await refresh() }
    }

    private func refresh() async {
        await model.refresh { try await remote.maintenanceStatus() }
    }

    private func submit(_ action: CantripMaintenanceAction) async {
        await model.submit(action) { try await remote.startMaintenance($0) }
    }
}
