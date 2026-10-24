import Foundation

extension VoiceVocabularyService.Inputs {
    /// Copies plain values on the main actor: custom names of open, non-private project tabs,
    /// the Home store's tasks (converted later, off the main actor), and the memory folder.
    @MainActor
    static func current(manager: SessionManager?) -> Self {
        let titles = manager?.sessions
            .filter { !$0.isPrivate && !$0.isLocalPrivate && !SessionManager.isCantripHomeReserved($0) }
            .compactMap { $0.tabMetadata.customTitle } ?? []
        let tasks = CantripHomeStore.shared.tasks
        let path = AppSettings.shared.memoryPath
        return Self(
            tabTitles: titles,
            homeTasks: { tasks.map(VoiceVocabulary.HomeTask.init) },
            memoryDirectory: path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : URL(fileURLWithPath: path)
        )
    }
}

extension VoiceVocabulary.HomeTask {
    init(_ task: CantripHomeTask) {
        self.init(title: task.title, workspace: task.workspace.map { workspace in
            VoiceVocabulary.Workspace(
                fields: workspace.fields.map { .init(key: $0.key, kind: $0.kind.rawValue, label: $0.label) },
                records: workspace.records.map { .init(values: $0.values) }
            )
        })
    }
}
