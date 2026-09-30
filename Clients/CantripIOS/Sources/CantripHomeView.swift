import QuickLook
import SwiftUI

enum CantripHomeSection: String, CaseIterable, Identifiable {
    case chat
    case tasks
    case artifacts

    var id: Self { self }
    var title: String { rawValue.capitalized }
    var systemImage: String {
        switch self {
        case .chat: "bubble.left.and.bubble.right"
        case .tasks: "checklist"
        case .artifacts: "square.grid.2x2"
        }
    }
}

struct CantripHomeTabBar: View {
    @Binding var selection: CantripHomeSection
    let runningTasks: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(CantripHomeSection.allCases) { section in
                Button {
                    selection = section
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: section.systemImage)
                            .font(.system(size: 18, weight: selection == section ? .semibold : .regular))
                            .overlay(alignment: .topTrailing) {
                                if section == .tasks, runningTasks > 0 {
                                    Text("\(min(runningTasks, 99))")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 4)
                                        .frame(minWidth: 16, minHeight: 16)
                                        .background(.orange, in: Capsule())
                                        .offset(x: 10, y: -8)
                                }
                            }
                        Text(section.title)
                            .font(.caption2.weight(selection == section ? .semibold : .regular))
                    }
                    .foregroundStyle(selection == section ? Color.accentColor : .secondary)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == section ? .isSelected : [])
            }
        }
        .padding(.horizontal, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Cantrip Home")
        .accessibilityIdentifier("home.tabBar")
    }
}

struct CantripHomeTasksView: View {
    @ObservedObject var remote: CantripRemoteModel
    let openChat: (String?) -> Void
    @State private var editing: CantripHomeTask?
    @State private var deleting: CantripHomeTask?

    var body: some View {
        Group {
            if remote.selectedSession?.isCantripHome != true {
                ContentUnavailableView(
                    "Cantrip Home unavailable",
                    systemImage: "house.slash",
                    description: Text(remote.detailError
                        ?? "Enable Cantrip Home in the Mac app's settings.")
                )
            } else if remote.homeTasks.isEmpty, !remote.isLoadingHomeData {
                ContentUnavailableView {
                    Label("No tasks yet", systemImage: "checklist")
                } description: {
                    Text("Ask Cantrip Home to monitor something once, on an interval, or on selected weekdays.")
                } actions: {
                    Button("Create in Chat") { openChat("Create a task to ") }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    if let error = remote.homeDataError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    ForEach(remote.homeTasks) { task in
                        taskRow(task)
                            .contentShape(Rectangle())
                            .onTapGesture { editing = task }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    deleting = task
                                }
                            }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Tasks")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openChat("Create a task to ")
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Create task in Chat")
            }
        }
        .refreshable { await remote.refreshHomeData() }
        .task { await remote.refreshHomeData() }
        .sheet(item: $editing) { task in
            CantripHomeTaskEditView(remote: remote, task: task, openChat: openChat)
        }
        .confirmationDialog(
            "Delete \(deleting?.title ?? "task")?",
            isPresented: Binding(
                get: { deleting != nil },
                set: { if !$0 { deleting = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let deleting {
                Button("Delete task", role: .destructive) {
                    let task = deleting
                    self.deleting = nil
                    Task { _ = await remote.deleteHomeTask(task) }
                }
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        }
    }

    private func taskRow(_ task: CantripHomeTask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                taskStatus(task)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(task.schedule.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(
                    get: { task.enabled },
                    set: { enabled in
                        Task { _ = await remote.updateHomeTask(task, enabled: enabled) }
                    }
                ))
                .labelsHidden()
                .disabled(remote.isMutating || task.state == "running")
                .accessibilityLabel(task.enabled ? "Pause \(task.title)" : "Resume \(task.title)")
            }
            Text(task.prompt)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .padding(.leading, 32)
            HStack(spacing: 6) {
                if let next = task.nextRunAt, task.enabled {
                    Label(next.formatted(.relative(presentation: .named)), systemImage: "clock")
                } else {
                    Label("Paused", systemImage: "pause")
                }
                if let run = task.runs.first {
                    Text("·")
                    Text(run.status.capitalized)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.leading, 32)
            if let run = task.runs.first, !run.summary.isEmpty {
                Text(run.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(.leading, 32)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func taskStatus(_ task: CantripHomeTask) -> some View {
        switch task.state {
        case "running":
            ProgressView().controlSize(.small)
        case "failed":
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case "succeeded":
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case "paused":
            Image(systemName: "pause.circle.fill").foregroundStyle(.secondary)
        default:
            Image(systemName: "clock.fill").foregroundStyle(.blue)
        }
    }
}

private struct CantripHomeTaskEditView: View {
    @ObservedObject var remote: CantripRemoteModel
    let task: CantripHomeTask
    let openChat: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var prompt: String
    @State private var saving = false

    init(remote: CantripRemoteModel, task: CantripHomeTask,
         openChat: @escaping (String?) -> Void) {
        self.remote = remote
        self.task = task
        self.openChat = openChat
        _title = State(initialValue: task.title)
        _prompt = State(initialValue: task.prompt)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Task") {
                    TextField("Title", text: $title)
                    TextField("Instructions", text: $prompt, axis: .vertical)
                        .lineLimit(4...12)
                }
                Section("Schedule") {
                    LabeledContent("Runs", value: task.schedule.summary)
                    LabeledContent("Time zone", value: task.schedule.timeZone)
                    Text("To change the schedule, ask Cantrip Home in Chat.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Change schedule in Chat") {
                        dismiss()
                        openChat("Change the schedule for \(task.title) to ")
                    }
                }
                if let run = task.runs.first {
                    Section("Latest run") {
                        LabeledContent("Status", value: run.status.capitalized)
                        Text(run.summary)
                    }
                }
            }
            .navigationTitle("Edit Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") {
                        saving = true
                        Task {
                            let saved = await remote.updateHomeTask(
                                task, title: title, prompt: prompt
                            )
                            saving = false
                            if saved { dismiss() }
                        }
                    }
                    .disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct CantripHomeArtifactsView: View {
    @ObservedObject var remote: CantripRemoteModel
    let openChat: (String?) -> Void
    @State private var previewURL: URL?
    @State private var loadingID: UUID?
    @State private var previewError: String?

    private let columns = [
        GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)
    ]

    var body: some View {
        Group {
            if remote.selectedSession?.isCantripHome != true {
                ContentUnavailableView(
                    "Cantrip Home unavailable",
                    systemImage: "house.slash",
                    description: Text(remote.detailError
                        ?? "Enable Cantrip Home in the Mac app's settings.")
                )
            } else if remote.homeArtifacts.isEmpty, !remote.isLoadingHomeData {
                ContentUnavailableView {
                    Label("No artifacts yet", systemImage: "square.grid.2x2")
                } description: {
                    Text("Documents and media created in Cantrip Home are collected here automatically.")
                } actions: {
                    Button("Create in Chat") { openChat("Create a ") }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ScrollView {
                    if let error = remote.homeDataError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(remote.homeArtifacts) { artifact in
                            artifactCard(artifact)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Artifacts")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openChat("Create a ")
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Create artifact in Chat")
            }
        }
        .refreshable { await remote.refreshHomeData() }
        .task { await remote.refreshHomeData() }
        .quickLookPreview($previewURL)
        .alert("Could not open artifact", isPresented: Binding(
            get: { previewError != nil },
            set: { if !$0 { previewError = nil } }
        )) {
            Button("OK", role: .cancel) { previewError = nil }
        } message: {
            Text(previewError ?? "")
        }
    }

    private func artifactCard(_ artifact: CantripHomeArtifact) -> some View {
        Button {
            guard loadingID == nil else { return }
            loadingID = artifact.id
            Task {
                defer { loadingID = nil }
                do { previewURL = try await remote.homeArtifactFile(artifact) }
                catch { previewError = error.localizedDescription }
            }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.accentColor.opacity(0.1))
                    if loadingID == artifact.id {
                        ProgressView()
                    } else {
                        Image(systemName: artifactIcon(artifact))
                            .font(.system(size: 34))
                            .foregroundStyle(.tint)
                    }
                }
                .frame(height: 104)
                Text(artifact.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                HStack {
                    Text(artifact.kind.capitalized)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(artifact.size), countStyle: .file))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(loadingID != nil)
        .accessibilityLabel("\(artifact.title), \(artifact.kind)")
    }

    private func artifactIcon(_ artifact: CantripHomeArtifact) -> String {
        switch artifact.kind {
        case "image": "photo"
        case "video": "play.rectangle.fill"
        case "audio": "waveform"
        default:
            artifact.mimeType == "application/pdf" ? "doc.richtext.fill" : "doc.text.fill"
        }
    }
}
