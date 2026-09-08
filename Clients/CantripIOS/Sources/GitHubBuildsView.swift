import SwiftUI

struct CantripBuildSnapshot: Decodable {
    var repositories: [CantripBuildRepository]
    var isRefreshing: Bool
    var error: String?

    var entries: [CantripBuildEntry] {
        repositories.flatMap { repository in
            repository.jobs.map { CantripBuildEntry(repository: repository, job: $0) }
        }.sorted { ($0.job.createdAt, $0.id) < ($1.job.createdAt, $1.id) }
    }

    var isComplete: Bool {
        error == nil && !repositories.isEmpty
            && repositories.allSatisfy { !$0.isStale }
    }
}

struct CantripBuildRepository: Decodable, Identifiable {
    let repository: String
    let app: String
    let runner: String
    let runnerStatus: String
    let busy: Bool
    let checkedAt: String?
    let jobs: [CantripBuildJob]
    let warning: String?
    var id: String { repository }
    var checkedDate: Date? { checkedAt.flatMap { ISO8601DateFormatter().date(from: $0) } }
    var isStale: Bool {
        warning != nil || checkedDate.map { Date().timeIntervalSince($0) > 120 } ?? true
    }
}

struct CantripBuildJob: Decodable, Identifiable {
    let id: String
    let workflow: String
    let title: String
    let number: Int
    let attempt: Int
    let branch: String
    let commit: String
    let status: String
    let job: String
    let step: String?
    let createdAt: String
    let startedAt: String?
    let url: String
    let assignment: String

    var isRunning: Bool { assignment == "assigned" && status == "in_progress" }
    var isWorkflowWait: Bool { assignment == "workflow" }
    var statusTitle: String {
        if isWorkflowWait { return "Workflow waiting" }
        switch status {
        case "in_progress": return isRunning ? "Running" : "Awaiting runner"
        case "queued": return "Queued"
        case "waiting": return "Waiting"
        case "pending": return "Pending"
        case "requested": return "Requested"
        default: return status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

struct CantripBuildEntry: Identifiable {
    let repository: CantripBuildRepository
    let job: CantripBuildJob
    var id: String { job.id }
    var githubURL: URL? {
        guard let url = URL(string: job.url), url.scheme == "https",
              url.host == "github.com", url.user == nil, url.password == nil,
              url.port == nil,
              url.path.hasPrefix("/\(repository.repository)/actions/runs/") else { return nil }
        return url
    }
}

@MainActor
final class GitHubBuildsModel: ObservableObject {
    @Published private(set) var snapshot: CantripBuildSnapshot?
    @Published private(set) var error: String?
    @Published private(set) var isLoading = false

    func refresh(_ load: () async throws -> CantripBuildSnapshot) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let value = try await load()
            try Task.checkCancellation()
            snapshot = value
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct GitHubBuildsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var remote: CantripRemoteModel
    @StateObject private var model = GitHubBuildsModel()

    var body: some View {
        NavigationStack {
            List {
                statusSection
                if let snapshot = model.snapshot {
                    let entries = snapshot.entries
                    buildSection("Building now", entries: entries.filter { $0.job.isRunning })
                    buildSection("Queued / waiting", entries: entries.filter { !$0.job.isRunning && !$0.job.isWorkflowWait })
                    buildSection("Waiting workflows", entries: entries.filter { $0.job.isWorkflowWait })
                    if entries.isEmpty && snapshot.isComplete && model.error == nil
                        && !snapshot.repositories.contains(where: \.busy) {
                        Section {
                            Label("No active builds reported", systemImage: "checkmark.circle")
                            Text("None of the monitored runners have running or queued jobs in the latest snapshot.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !snapshot.repositories.isEmpty {
                        Section("Runners") {
                            ForEach(snapshot.repositories) { repository in
                                runnerRow(repository)
                            }
                        }
                    }
                }
            }
            .navigationTitle("GitHub Builds")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { Task { await refresh() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(model.isLoading)
                    .accessibilityLabel("Refresh GitHub builds")
                }
            }
            .refreshable { await refresh() }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    await refresh()
                    do {
                        try await Task.sleep(for: .seconds(model.snapshot?.isRefreshing == true ? 3 : 10))
                    } catch { return }
                }
            }
        }
    }

    private var statusSection: some View {
        Section {
            if model.isLoading || model.snapshot?.isRefreshing == true {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Checking GitHub builds...").font(.subheadline)
                }
            }
            if let error = model.error ?? model.snapshot?.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                if model.snapshot != nil {
                    Text("Showing the last snapshot; build and runner states may be out of date.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Read-only view across your apps. The Mac checks GitHub at most once a minute while this screen is open.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Waiting work is oldest-first, not a guaranteed build order. Eligible jobs are not yet assigned; workflow waits may be for approval, concurrency, or dependencies.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func buildSection(_ title: String, entries: [CantripBuildEntry]) -> some View {
        if !entries.isEmpty {
            Section("\(title) (\(entries.count))") {
                ForEach(entries) { entry in
                    GitHubBuildRow(entry: entry)
                }
            }
        }
    }

    private func runnerRow(_ repository: CantripBuildRepository) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(repository.app).font(.headline)
            Text(repository.runner).font(.subheadline)
            Text(repository.repository).font(.caption).foregroundStyle(.secondary)
            Label(
                repository.isStale ? "Status unavailable / stale" :
                    "\(repository.runnerStatus.capitalized) - \(repository.busy ? "Busy" : "Idle")",
                systemImage: repository.isStale ? "exclamationmark.triangle" : "desktopcomputer"
            )
            .font(.caption)
            .foregroundStyle(repository.isStale || repository.runnerStatus != "online" ? Color.orange : Color.secondary)
            if let warning = repository.warning {
                Text(warning).font(.caption).foregroundStyle(.orange)
            }
            if repository.busy && !repository.jobs.contains(where: \.isRunning) && !repository.isStale {
                Text("Runner reports busy; GitHub has not reported a matching running job yet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let checked = repository.checkedDate {
                HStack(spacing: 4) {
                    Text("Checked")
                    Text(checked, style: .relative)
                    Text("ago")
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func refresh() async {
        await model.refresh { try await remote.githubBuilds() }
    }
}

struct GitHubBuildRow: View {
    let entry: CantripBuildEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.repository.app).font(.headline)
            Label(entry.job.statusTitle, systemImage: entry.job.isRunning ? "hammer.fill" : "clock")
                .font(.caption.weight(.semibold))
                .foregroundStyle(entry.job.isRunning ? Color.accentColor : Color.secondary)
            if entry.repository.isStale {
                Label("Last known state - data is stale", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("\(entry.job.workflow) #\(entry.job.number) - attempt \(entry.job.attempt)")
                .font(.subheadline)
            Text(entry.job.job).font(.subheadline.weight(.medium))
            if let step = entry.job.step {
                Text("Current step: \(step)").font(.subheadline)
            }
            if entry.job.title != entry.job.workflow {
                Text(entry.job.title).font(.caption).foregroundStyle(.secondary)
            }
            Text("\(entry.job.branch) - \(String(entry.job.commit.prefix(7)))")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            Text(assignmentText).font(.caption).foregroundStyle(.secondary)
            if let started = (entry.job.isRunning ? entry.job.startedAt : entry.job.createdAt)
                .flatMap({ ISO8601DateFormatter().date(from: $0) }) {
                HStack(spacing: 4) {
                    Text(entry.job.isRunning ? "Started" : "Workflow created")
                    Text(started, style: .relative)
                    Text("ago")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            if let url = entry.githubURL {
                Link(destination: url) {
                    Label("Open in GitHub", systemImage: "arrow.up.right.square")
                        .font(.subheadline)
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
        .textSelection(.enabled)
    }

    private var assignmentText: String {
        switch entry.job.assignment {
        case "assigned": return "Runner: \(entry.repository.runner)"
        case "eligible": return "Eligible for \(entry.repository.runner); not yet assigned"
        default: return "Repository workflow; runner eligibility not yet known"
        }
    }
}
