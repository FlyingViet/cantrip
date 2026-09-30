import Combine
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

struct CantripHomeTabs<ChatContent: View, TasksContent: View, ArtifactsContent: View>: View {
    @Binding var selection: CantripHomeSection
    let runningTasks: Int
    private let chat: ChatContent
    private let tasks: TasksContent
    private let artifacts: ArtifactsContent

    init(
        selection: Binding<CantripHomeSection>,
        runningTasks: Int,
        @ViewBuilder chat: () -> ChatContent,
        @ViewBuilder tasks: () -> TasksContent,
        @ViewBuilder artifacts: () -> ArtifactsContent
    ) {
        _selection = selection
        self.runningTasks = runningTasks
        self.chat = chat()
        self.tasks = tasks()
        self.artifacts = artifacts()
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab(
                CantripHomeSection.chat.title,
                systemImage: CantripHomeSection.chat.systemImage,
                value: CantripHomeSection.chat
            ) {
                chat
            }
            Tab(
                CantripHomeSection.tasks.title,
                systemImage: CantripHomeSection.tasks.systemImage,
                value: CantripHomeSection.tasks
            ) {
                tasks
            }
            .badge(runningTasks)
            Tab(
                CantripHomeSection.artifacts.title,
                systemImage: CantripHomeSection.artifacts.systemImage,
                value: CantripHomeSection.artifacts
            ) {
                artifacts
            }
        }
        .tabViewStyle(.tabBarOnly)
        .tabBarMinimizeBehavior(.onScrollDown)
        .accessibilityIdentifier("home.tabView")
    }
}

struct CantripHomeTasksView: View {
    let remote: CantripRemoteModel
    let openChat: (String?) -> Void
    @State private var tasks: [CantripHomeTask]
    @State private var homeDataError: String?
    @State private var isLoadingHomeData: Bool
    @State private var homeAvailable: Bool
    @State private var detailError: String?
    @State private var editing: CantripHomeTask?
    @State private var deleting: CantripHomeTask?

    init(remote: CantripRemoteModel, openChat: @escaping (String?) -> Void) {
        self.remote = remote
        self.openChat = openChat
        _tasks = State(initialValue: remote.homeTasks)
        _homeDataError = State(initialValue: remote.homeDataError)
        _isLoadingHomeData = State(initialValue: remote.isLoadingHomeData)
        _homeAvailable = State(initialValue: remote.selectedSession?.isCantripHome == true)
        _detailError = State(initialValue: remote.detailError)
    }

    var body: some View {
        Group {
            if !homeAvailable {
                ContentUnavailableView(
                    "Cantrip Home unavailable",
                    systemImage: "house.slash",
                    description: Text(detailError
                        ?? "Enable Cantrip Home in the Mac app's settings.")
                )
            } else if tasks.isEmpty, !isLoadingHomeData {
                ContentUnavailableView {
                    Label("No tasks yet", systemImage: "checklist")
                } description: {
                    Text("Ask Cantrip Home to create a tracker or monitor something on a schedule.")
                } actions: {
                    Button("Create in Chat") { openChat("Create a task for ") }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    if let error = homeDataError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    ForEach(tasks) { task in
                        if task.workspace != nil {
                            NavigationLink {
                                CantripHomeTaskWorkspaceView(
                                    remote: remote, taskID: task.id, openChat: openChat
                                )
                            } label: {
                                taskRow(task)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    deleting = task
                                }
                            }
                        } else {
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
        .onReceive(remote.$homeTasks.removeDuplicates()) { tasks = $0 }
        .onReceive(remote.$homeDataError.removeDuplicates()) { homeDataError = $0 }
        .onReceive(remote.$isLoadingHomeData.removeDuplicates()) { isLoadingHomeData = $0 }
        .onReceive(
            remote.$selectedSession
                .map { $0?.isCantripHome == true }
                .removeDuplicates()
        ) { homeAvailable = $0 }
        .onReceive(remote.$detailError.removeDuplicates()) { detailError = $0 }
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
                    if let workspace = task.workspace {
                        Text("\(workspace.records.count) \(recordCountLabel(workspace))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(task.schedule.summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if task.isScheduled {
                    Toggle("", isOn: Binding(
                        get: { task.enabled },
                        set: { enabled in
                            Task { _ = await remote.updateHomeTask(task, enabled: enabled) }
                        }
                    ))
                    .labelsHidden()
                    .disabled(remote.isMutating || task.state == "running")
                    .accessibilityLabel(
                        task.enabled ? "Pause \(task.title)" : "Resume \(task.title)"
                    )
                }
            }
            Text(task.prompt)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .padding(.leading, 32)
            HStack(spacing: 6) {
                if !task.isScheduled {
                    Label("Updated \(task.updatedAt.formatted(.relative(presentation: .named)))",
                          systemImage: "rectangle.stack")
                } else if let next = task.nextRunAt, task.enabled {
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

    private func recordCountLabel(_ workspace: CantripHomeTaskWorkspace) -> String {
        workspace.records.count == 1
            ? workspace.recordLabel
            : workspace.recordLabelPlural ?? "\(workspace.recordLabel)s"
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
        case "ready":
            Image(systemName: task.workspace?.icon ?? "rectangle.stack.fill")
                .foregroundStyle(.tint)
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
                if task.isScheduled {
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
                }
                if let workspace = task.workspace {
                    Section("Workspace") {
                        LabeledContent(
                            workspace.recordLabel,
                            value: "\(workspace.records.count)"
                        )
                        LabeledContent("Fields", value: "\(workspace.fields.count)")
                        Button("Change workspace in Chat") {
                            dismiss()
                            openChat("Change the workspace for \(task.title) to ")
                        }
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

private struct CantripHomeRecordEditorTarget: Identifiable {
    let id = UUID()
    let record: CantripHomeTaskRecord?
}

struct CantripHomeTaskWorkspaceView: View {
    let remote: CantripRemoteModel
    let taskID: UUID
    let openChat: (String?) -> Void
    @State private var tasks: [CantripHomeTask]
    @State private var search = ""
    @State private var editorTarget: CantripHomeRecordEditorTarget?
    @State private var deleting: CantripHomeTaskRecord?
    @State private var showingSettings = false

    init(
        remote: CantripRemoteModel, taskID: UUID,
        openChat: @escaping (String?) -> Void
    ) {
        self.remote = remote
        self.taskID = taskID
        self.openChat = openChat
        _tasks = State(initialValue: remote.homeTasks)
    }

    private var task: CantripHomeTask? {
        tasks.first { $0.id == taskID }
    }

    private var records: [CantripHomeTaskRecord] {
        guard let records = task?.workspace?.records else { return [] }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return records }
        return records.filter { record in
            record.values.values.contains {
                $0.localizedCaseInsensitiveContains(query)
            }
        }
    }

    var body: some View {
        Group {
            if let task, let workspace = task.workspace {
                if workspace.records.isEmpty {
                    ContentUnavailableView {
                        Label(
                            "No \(pluralLabel(workspace)) yet",
                            systemImage: workspace.icon
                        )
                    } description: {
                        Text("Add one here or tell Cantrip Home about it in Chat.")
                    } actions: {
                        Button("Add \(workspace.recordLabel)") {
                            editorTarget = .init(record: nil)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        if let error = remote.homeDataError {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        ForEach(records) { record in
                            NavigationLink {
                                CantripHomeTaskRecordDetailView(
                                    remote: remote, taskID: taskID, recordID: record.id
                                )
                            } label: {
                                recordRow(record, workspace: workspace)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    deleting = record
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .searchable(text: $search, prompt: "Search \(pluralLabel(workspace))")
                }
            } else {
                ContentUnavailableView(
                    "Task unavailable",
                    systemImage: "rectangle.stack.badge.exclamationmark",
                    description: Text("Refresh Tasks and try again.")
                )
            }
        }
        .navigationTitle(task?.title ?? "Task")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Task settings")
                Button {
                    editorTarget = .init(record: nil)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add \(task?.workspace?.recordLabel ?? "record")")
            }
        }
        .sheet(item: $editorTarget) { target in
            if let task, let workspace = task.workspace {
                CantripHomeTaskRecordEditor(
                    remote: remote, taskID: task.id, workspace: workspace,
                    record: target.record
                )
            }
        }
        .sheet(isPresented: $showingSettings) {
            if let task {
                CantripHomeTaskEditView(
                    remote: remote, task: task, openChat: openChat
                )
            }
        }
        .confirmationDialog(
            "Delete \(task?.workspace?.recordLabel.lowercased() ?? "record")?",
            isPresented: Binding(
                get: { deleting != nil },
                set: { if !$0 { deleting = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let deleting {
                Button("Delete", role: .destructive) {
                    let record = deleting
                    self.deleting = nil
                    Task {
                        _ = await remote.deleteHomeTaskRecord(
                            taskID: taskID, recordID: record.id
                        )
                    }
                }
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        }
        .onReceive(remote.$homeTasks.removeDuplicates()) { tasks = $0 }
    }

    private func pluralLabel(_ workspace: CantripHomeTaskWorkspace) -> String {
        workspace.recordLabelPlural ?? "\(workspace.recordLabel)s"
    }

    private func recordRow(
        _ record: CantripHomeTaskRecord, workspace: CantripHomeTaskWorkspace
    ) -> some View {
        let presentation = workspace.list
        let title = record.values[presentation.titleField] ?? workspace.recordLabel
        let subtitles = presentation.subtitleFields.compactMap { key -> String? in
            guard let value = record.values[key],
                  let field = workspace.fields.first(where: { $0.key == key }) else { return nil }
            return "\(field.label): \(CantripHomeTaskValueFormatter.display(value, for: field))"
        }
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: workspace.icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    if let key = presentation.badgeField,
                       let badge = record.values[key], !badge.isEmpty {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tint)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                }
                if !subtitles.isEmpty {
                    Text(subtitles.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let key = presentation.dateField,
                   let value = record.values[key],
                   let field = workspace.fields.first(where: { $0.key == key }) {
                    Label(
                        CantripHomeTaskValueFormatter.display(value, for: field),
                        systemImage: "calendar"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 5)
    }
}

private struct CantripHomeTaskRecordDetailView: View {
    @ObservedObject var remote: CantripRemoteModel
    let taskID: UUID
    let recordID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var editorTarget: CantripHomeRecordEditorTarget?
    @State private var confirmingDelete = false

    private var task: CantripHomeTask? {
        remote.homeTasks.first { $0.id == taskID }
    }

    private var workspace: CantripHomeTaskWorkspace? { task?.workspace }

    private var record: CantripHomeTaskRecord? {
        workspace?.records.first { $0.id == recordID }
    }

    private var title: String {
        guard let workspace, let record else { return "Record" }
        return record.values[workspace.list.titleField] ?? workspace.recordLabel
    }

    var body: some View {
        Group {
            if let workspace, let record {
                List {
                    ForEach(sections(workspace)) { section in
                        Section(section.title ?? "") {
                            ForEach(section.fields, id: \.self) { key in
                                if let field = workspace.fields.first(where: { $0.key == key }) {
                                    recordValue(field, record: record)
                                }
                            }
                        }
                    }
                    Section {
                        LabeledContent(
                            "Updated",
                            value: record.updatedAt.formatted(
                                date: .abbreviated, time: .shortened
                            )
                        )
                    }
                }
            } else {
                ContentUnavailableView(
                    "Record unavailable",
                    systemImage: "doc.questionmark",
                    description: Text("It may have been removed.")
                )
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Edit") {
                    if let record { editorTarget = .init(record: record) }
                }
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Delete record")
            }
        }
        .sheet(item: $editorTarget) { target in
            if let workspace {
                CantripHomeTaskRecordEditor(
                    remote: remote, taskID: taskID, workspace: workspace,
                    record: target.record
                )
            }
        }
        .confirmationDialog(
            "Delete \(workspace?.recordLabel.lowercased() ?? "record")?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    if await remote.deleteHomeTaskRecord(
                        taskID: taskID, recordID: recordID
                    ) {
                        dismiss()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func sections(
        _ workspace: CantripHomeTaskWorkspace
    ) -> [CantripHomeTaskDetailSection] {
        workspace.detailSections.isEmpty
            ? [.init(title: nil, fields: workspace.fields.map(\.key))]
            : workspace.detailSections
    }

    @ViewBuilder
    private func recordValue(
        _ field: CantripHomeTaskField, record: CantripHomeTaskRecord
    ) -> some View {
        let value = record.values[field.key]
        LabeledContent {
            if field.kind == .url, let value, let url = URL(string: value) {
                Link(value, destination: url)
                    .multilineTextAlignment(.trailing)
            } else {
                Text(value.map { CantripHomeTaskValueFormatter.display($0, for: field) } ?? "—")
                    .foregroundStyle(value == nil ? .secondary : .primary)
                    .multilineTextAlignment(.trailing)
            }
        } label: {
            Text(field.label)
        }
    }
}

private struct CantripHomeTaskRecordEditor: View {
    @ObservedObject var remote: CantripRemoteModel
    let taskID: UUID
    let workspace: CantripHomeTaskWorkspace
    let record: CantripHomeTaskRecord?
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String]
    @State private var saving = false

    init(
        remote: CantripRemoteModel, taskID: UUID, workspace: CantripHomeTaskWorkspace,
        record: CantripHomeTaskRecord?
    ) {
        self.remote = remote
        self.taskID = taskID
        self.workspace = workspace
        self.record = record
        var initial = record?.values ?? [:]
        for field in workspace.fields where initial[field.key] == nil {
            switch field.kind {
            case .boolean:
                initial[field.key] = "false"
            case .date where field.required:
                initial[field.key] = CantripHomeTaskValueFormatter.dateValue(Date())
            case .dateTime where field.required:
                initial[field.key] = CantripHomeTaskValueFormatter.dateTimeValue(Date())
            default:
                break
            }
        }
        _values = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                if let error = remote.homeDataError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Section(workspace.recordLabel) {
                    ForEach(workspace.fields) { field in
                        fieldEditor(field)
                    }
                }
            }
            .navigationTitle(record == nil ? "Add \(workspace.recordLabel)" : "Edit \(workspace.recordLabel)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") {
                        saving = true
                        Task {
                            let saved = await remote.saveHomeTaskRecord(
                                taskID: taskID, recordID: record?.id, values: values
                            )
                            saving = false
                            if saved { dismiss() }
                        }
                    }
                    .disabled(saving || !canSave)
                }
            }
        }
    }

    private var canSave: Bool {
        workspace.fields.allSatisfy { field in
            !field.required
                || !(values[field.key] ?? "").trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
        }
    }

    @ViewBuilder
    private func fieldEditor(_ field: CantripHomeTaskField) -> some View {
        switch field.kind {
        case .text:
            TextField(field.label, text: valueBinding(field.key))
        case .longText:
            TextField(field.label, text: valueBinding(field.key), axis: .vertical)
                .lineLimit(3...10)
        case .number:
            TextField(field.label, text: valueBinding(field.key))
                .keyboardType(.decimalPad)
        case .boolean:
            Toggle(field.label, isOn: Binding(
                get: { values[field.key] == "true" },
                set: { values[field.key] = $0 ? "true" : "false" }
            ))
        case .date:
            DatePicker(
                field.label,
                selection: dateBinding(field.key, includesTime: false),
                displayedComponents: .date
            )
        case .dateTime:
            DatePicker(
                field.label,
                selection: dateBinding(field.key, includesTime: true),
                displayedComponents: [.date, .hourAndMinute]
            )
        case .choice:
            Picker(field.label, selection: valueBinding(field.key)) {
                Text("Select").tag("")
                ForEach(field.options ?? [], id: \.self) { option in
                    Text(option).tag(option)
                }
            }
        case .url:
            TextField(field.label, text: valueBinding(field.key))
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    private func valueBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { values[key] ?? "" },
            set: { values[key] = $0 }
        )
    }

    private func dateBinding(_ key: String, includesTime: Bool) -> Binding<Date> {
        Binding(
            get: {
                guard let value = values[key] else { return Date() }
                return includesTime
                    ? CantripHomeTaskValueFormatter.parseDateTime(value) ?? Date()
                    : CantripHomeTaskValueFormatter.parseDate(value) ?? Date()
            },
            set: {
                values[key] = includesTime
                    ? CantripHomeTaskValueFormatter.dateTimeValue($0)
                    : CantripHomeTaskValueFormatter.dateValue($0)
            }
        )
    }
}

private enum CantripHomeTaskValueFormatter {
    static func display(_ value: String, for field: CantripHomeTaskField) -> String {
        switch field.kind {
        case .boolean:
            return value == "true" ? "Yes" : "No"
        case .date:
            return parseDate(value)?.formatted(date: .abbreviated, time: .omitted) ?? value
        case .dateTime:
            return parseDateTime(value)?.formatted(date: .abbreviated, time: .shortened) ?? value
        default:
            return value
        }
    }

    static func parseDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }

    static func parseDateTime(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }

    static func dateValue(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func dateTimeValue(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

struct CantripHomeArtifactsView: View {
    let remote: CantripRemoteModel
    let openChat: (String?) -> Void
    @State private var artifacts: [CantripHomeArtifact]
    @State private var homeDataError: String?
    @State private var isLoadingHomeData: Bool
    @State private var homeAvailable: Bool
    @State private var detailError: String?
    @State private var previewURL: URL?
    @State private var loadingID: UUID?
    @State private var previewError: String?
    @State private var deleting: CantripHomeArtifact?

    private let columns = [
        GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)
    ]

    init(remote: CantripRemoteModel, openChat: @escaping (String?) -> Void) {
        self.remote = remote
        self.openChat = openChat
        _artifacts = State(initialValue: remote.homeArtifacts)
        _homeDataError = State(initialValue: remote.homeDataError)
        _isLoadingHomeData = State(initialValue: remote.isLoadingHomeData)
        _homeAvailable = State(initialValue: remote.selectedSession?.isCantripHome == true)
        _detailError = State(initialValue: remote.detailError)
    }

    var body: some View {
        Group {
            if !homeAvailable {
                ContentUnavailableView(
                    "Cantrip Home unavailable",
                    systemImage: "house.slash",
                    description: Text(detailError
                        ?? "Enable Cantrip Home in the Mac app's settings.")
                )
            } else if artifacts.isEmpty, !isLoadingHomeData {
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
                    if let error = homeDataError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(artifacts) { artifact in
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
        .onReceive(remote.$homeArtifacts.removeDuplicates()) { artifacts = $0 }
        .onReceive(remote.$homeDataError.removeDuplicates()) { homeDataError = $0 }
        .onReceive(remote.$isLoadingHomeData.removeDuplicates()) { isLoadingHomeData = $0 }
        .onReceive(
            remote.$selectedSession
                .map { $0?.isCantripHome == true }
                .removeDuplicates()
        ) { homeAvailable = $0 }
        .onReceive(remote.$detailError.removeDuplicates()) { detailError = $0 }
        .quickLookPreview($previewURL)
        .alert("Could not open artifact", isPresented: Binding(
            get: { previewError != nil },
            set: { if !$0 { previewError = nil } }
        )) {
            Button("OK", role: .cancel) { previewError = nil }
        } message: {
            Text(previewError ?? "")
        }
        .confirmationDialog(
            "Delete \(deleting?.title ?? "artifact")?",
            isPresented: Binding(
                get: { deleting != nil },
                set: { if !$0 { deleting = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let deleting {
                Button("Delete artifact", role: .destructive) {
                    let artifact = deleting
                    self.deleting = nil
                    Task { _ = await remote.deleteHomeArtifact(artifact) }
                }
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("This permanently deletes the file from your Mac.")
        }
    }

    private func artifactCard(_ artifact: CantripHomeArtifact) -> some View {
        ZStack(alignment: .topTrailing) {
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
                        Text(ByteCountFormatter.string(
                            fromByteCount: Int64(artifact.size), countStyle: .file
                        ))
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

            Menu {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    deleting = artifact
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .background(.regularMaterial, in: Circle())
                    .contentShape(Circle())
            }
            .padding(16)
            .disabled(loadingID != nil)
            .accessibilityLabel("Actions for \(artifact.title)")
        }
        .contextMenu {
            Button("Delete", systemImage: "trash", role: .destructive) {
                deleting = artifact
            }
        }
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
