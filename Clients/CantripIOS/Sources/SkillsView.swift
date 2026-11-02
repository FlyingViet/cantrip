import SwiftUI

/// Browse all of the gateway's skills and run one — tapping sends it as a turn
/// and returns to the chat, where the interaction streams in. Fetches its own
/// list on open (with a loading state) so it never races the chat's preload.
struct SkillsView: View {
    let client: HermesClient?
    let onRun: (HermesCommand) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var skills: [HermesCommand] = []
    @State private var loading = true
    @State private var query = ""

    private var filtered: [HermesCommand] {
        guard !query.isEmpty else { return skills }
        return skills.filter {
            $0.command.localizedCaseInsensitiveContains(query) ||
            $0.description.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { skill in
                Button { onRun(skill) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "wand.and.stars").foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(skill.command).font(.callout.weight(.semibold).monospaced())
                            if !skill.description.isEmpty {
                                Text(skill.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "play.circle").foregroundStyle(.secondary)
                    }
                }
                .tint(.primary)
            }
            .listStyle(.plain)
            .searchable(text: $query, prompt: "Search skills")
            .navigationTitle("Skills")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .overlay {
                if loading {
                    ProgressView()
                } else if skills.isEmpty {
                    ContentUnavailableView("No skills", systemImage: "wand.and.stars",
                        description: Text("Your gateway didn't report any skills, or it's unreachable. Check Settings."))
                }
            }
        }
        .task {
            let all = await client?.commands() ?? []
            skills = all.filter { $0.kind == .skill }
            loading = false
        }
    }
}
