import AppKit
import SwiftUI

/// Settings › Agent policy: view and edit the rules every tab and backend follows, see what was
/// imported from each CLI and which imported rules a stricter rule overrides.
struct AgentPolicyView: View {
    @State private var policy = AgentPolicyGate.store.current()
    @State private var loadError = AgentPolicyGate.store.loadError
    @State private var error: String?
    @State private var showRules = false
    @State private var showAdd = false
    @State private var draft = Draft()

    struct Draft {
        var id = ""
        var effect = AgentPolicyRule.Effect.deny
        var reason = ""
        var commands = ""
        var paths = ""
        var mcp = ""
        var hours = ""
        var repos = ""

        func list(_ text: String) -> [String]? {
            let values = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return values.isEmpty ? nil : values
        }

        var rule: AgentPolicyRule {
            AgentPolicyRule(id: id.trimmingCharacters(in: .whitespaces), effect: effect,
                            reason: reason.trimmingCharacters(in: .whitespaces), source: "user",
                            commands: list(commands), paths: list(paths), mcp: list(mcp), hours: list(hours), repos: list(repos))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Agent policy").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open File") { NSWorkspace.shared.open(AgentPolicyGate.store.url) }
                    .disabled(!AgentPolicyGate.store.exists)
                Button("Reload") { reload() }
            }
            .font(.caption)
            Text("Every tab, child tab and Home run checks each tool call against these rules, on every backend. Deny beats ask and ask beats allow; anything no rule covers runs when Act on my behalf is on and asks when it's off. Paired clients see the same rules, and the browser Remote can edit them.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Check every tab against the policy", isOn: Binding(
                get: { policy.enabled },
                set: { value in save { $0.enabled = value } }
            ))
            .font(.caption).toggleStyle(.checkbox)
            DisclosureGroup(isExpanded: $showRules) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(AgentPolicyRule.Effect.allCases.reversed(), id: \.self) { effect in
                        let rules = policy.rules.filter { $0.effect == effect }
                        if !rules.isEmpty {
                            Text(heading(effect) + " (\(rules.count))").font(.caption.weight(.semibold))
                            ForEach(rules) { rule in row(rule) }
                        }
                    }
                    ForEach(policy.projects, id: \.path) { project in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("In \(project.path)").font(.caption.weight(.semibold))
                            if !project.disabled.isEmpty {
                                Text("Turned off here: " + project.disabled.joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary)
                            }
                            ForEach(project.rules) { rule in
                                Text("\(rule.effect.rawValue): \(rule.id) — \(rule.summary)").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    DisclosureGroup("Add a rule", isExpanded: $showAdd) { addForm }.font(.caption)
                }
                .padding(.top, 4)
            } label: {
                Text("Rules (\(policy.rules.count))").font(.caption)
            }
            if !policy.conflicts.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(policy.conflicts.enumerated()), id: \.offset) { _, conflict in
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(conflict.imported) → \(conflict.stricter)").font(.caption2.weight(.semibold))
                                Text(conflict.note).font(.caption2).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                } label: {
                    Text("Imported rules a stricter rule overrides (\(policy.conflicts.count))").font(.caption)
                }
            }
            if !policy.imports.isEmpty {
                Text("Imported: " + policy.imports.map { "\($0.source) \($0.rules)" }.joined(separator: " · ")
                     + ". Backups are in Application Support › Cantrip › policy-backups.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = error ?? loadError {
                Text(message).font(.caption2).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { reload() }
    }

    private func heading(_ effect: AgentPolicyRule.Effect) -> String {
        switch effect {
        case .deny: return "Always blocked"
        case .ask: return "Needs approval"
        case .allow: return "Always allowed"
        }
    }

    private func row(_ rule: AgentPolicyRule) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Toggle(rule.id, isOn: Binding(
                    get: { rule.enabled },
                    set: { value in save { document in
                        if let index = document.rules.firstIndex(where: { $0.id == rule.id }) { document.rules[index].enabled = value }
                    } }
                ))
                .toggleStyle(.checkbox).font(.caption)
                Spacer()
                Picker("", selection: Binding(
                    get: { rule.effect },
                    set: { value in save { document in
                        if let index = document.rules.firstIndex(where: { $0.id == rule.id }) { document.rules[index].effect = value }
                    } }
                )) {
                    Text("Deny").tag(AgentPolicyRule.Effect.deny)
                    Text("Ask").tag(AgentPolicyRule.Effect.ask)
                    Text("Allow").tag(AgentPolicyRule.Effect.allow)
                }
                .labelsHidden().frame(width: 80).controlSize(.small)
                Button {
                    save { $0.rules.removeAll { $0.id == rule.id } }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless).help("Remove \(rule.id)")
            }
            Text(rule.reason).font(.caption2).fixedSize(horizontal: false, vertical: true)
            Text(rule.summary).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let source = rule.source, source != "default", source != "user" {
                Text("From \(source)").font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
            }
        }
        .opacity(rule.enabled ? 1 : 0.55)
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("ID (no-release-on-fridays)", text: $draft.id)
                Picker("", selection: $draft.effect) {
                    Text("Deny").tag(AgentPolicyRule.Effect.deny)
                    Text("Ask").tag(AgentPolicyRule.Effect.ask)
                    Text("Allow").tag(AgentPolicyRule.Effect.allow)
                }
                .labelsHidden().frame(width: 80)
            }
            TextField("Reason, shown to the agent and on approval cards", text: $draft.reason)
            TextField("Commands, comma-separated (git push, re:…, @cantrip-restart)", text: $draft.commands)
            TextField("Paths, comma-separated ($WORKTREE, $PROJECT, $TMP, ~)", text: $draft.paths)
            TextField("MCP tools, comma-separated (server/tool, server/*)", text: $draft.mcp)
            TextField("Hours, comma-separated (21:45-22:50)", text: $draft.hours)
            TextField("Only in repositories, comma-separated", text: $draft.repos)
            HStack {
                Spacer()
                Button("Add Rule") {
                    let rule = draft.rule
                    save { $0.rules.append(rule) } done: { draft = Draft(); showAdd = false }
                }
                .disabled(draft.id.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
        .font(.caption)
    }

    private func reload() {
        policy = AgentPolicyGate.store.current()
        loadError = AgentPolicyGate.store.loadError
        error = nil
    }

    private func save(_ change: (inout AgentPolicyDocument) -> Void, done: (() -> Void)? = nil) {
        var document = policy
        change(&document)
        let revision = AgentPolicyGate.store.exists ? policy.revision : nil
        do {
            policy = try AgentPolicySetup.save(document, basedOn: revision)
            error = nil
            done?()
        } catch {
            self.error = error.localizedDescription
            policy = AgentPolicyGate.store.current()
        }
    }
}
