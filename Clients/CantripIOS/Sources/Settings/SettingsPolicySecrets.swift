import SwiftUI

/// `GET/POST /api/v1/policy`: the rules every tab and backend on the Mac follows.
struct CantripPolicySnapshot: Decodable, Equatable {
    struct Rule: Decodable, Equatable, Identifiable {
        let id: String
        let effect: String
        let reason: String
        let enabled: Bool
        let source: String?
        /// Every field as the Mac sent it, so an edit sends back what this client doesn't show.
        let raw: [String: MCPAppJSONValue]

        private enum CodingKeys: String, CodingKey { case id, effect, reason, enabled, source }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            effect = try container.decode(String.self, forKey: .effect)
            reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? ""
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            source = try container.decodeIfPresent(String.self, forKey: .source)
            if case .object(let object) = try MCPAppJSONValue(from: decoder) { raw = object } else { raw = [:] }
        }

        /// From another backend's settings (imported), not Cantrip's defaults or the user's own.
        var importedFrom: String? {
            guard let source, source != "default", source != "user" else { return nil }
            return source
        }
    }

    struct Project: Decodable, Equatable {
        let path: String
        var disabled: [String]? = nil
        var rules: [Rule]? = nil
    }

    struct Conflict: Decodable, Equatable {
        let imported: String
        let stricter: String
        let note: String
    }

    struct Document: Decodable, Equatable {
        let revision: Int
        let enabled: Bool
        let rules: [Rule]
        var projects: [Project]? = nil
        var conflicts: [Conflict]? = nil
    }

    let policy: Document
    let summaries: [String: String]
    let file: String
    let loadError: String?

    static let effects = ["deny", "ask", "allow"]

    static func heading(_ effect: String) -> String {
        switch effect {
        case "deny": return "Always blocked"
        case "ask": return "Needs approval"
        default: return "Always allowed"
        }
    }

    static func label(_ effect: String) -> String {
        switch effect {
        case "deny": return "Deny"
        case "ask": return "Ask"
        default: return "Allow"
        }
    }
}

/// `GET/POST /api/v1/secrets`: the Mac's secrets broker by name only, and Unlock & Sync.
struct CantripSecretsSnapshot: Decodable, Equatable {
    struct Item: Decodable, Equatable, Identifiable {
        let name: String
        let kind: String
        let fields: [String]
        var updated: String? = nil
        var id: String { name }
    }

    let folder: String
    let items: [Item]
    var skipped: [String]? = nil
    var lastSync: String? = nil
    var lastError: String? = nil
    var syncing: Bool? = nil
    var available: Bool? = nil
    var requestedBy: String? = nil
    var lastReport: String? = nil

    /// "12 secrets · synced 3 hours ago".
    func status(now: Date = Date()) -> String {
        let count = "\(items.count) secret\(items.count == 1 ? "" : "s")"
        guard let lastSync, let date = ISO8601DateFormatter().date(from: lastSync) else {
            return items.isEmpty ? "Not synced yet" : count
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "\(count) · synced \(formatter.localizedString(for: date, relativeTo: now))"
    }
}

/// Settings › Tools & sign-ins: the agent policy and secrets, each on its own screen.
struct SettingsRulesAndSecretsSection: View {
    @ObservedObject var remote: CantripRemoteModel

    var body: some View {
        Section {
            NavigationLink {
                SettingsAgentPolicyPage(remote: remote)
            } label: {
                Label("Agent policy", systemImage: "checkmark.shield")
            }
            .accessibilityIdentifier("settings.policy")
            NavigationLink {
                SettingsSecretsPage(remote: remote)
            } label: {
                Label("Secrets", systemImage: "key")
            }
            .accessibilityIdentifier("settings.secrets")
        } header: {
            Text("Rules and secrets")
        } footer: {
            Text("What agents may do on the Mac without asking, and the secrets its commands can use (by name; values never leave the Mac).")
        }
        .disabled(!remote.isConfigured)
    }
}

struct SettingsAgentPolicyPage: View {
    @ObservedObject var remote: CantripRemoteModel
    @State private var snapshot: CantripPolicySnapshot?
    @State private var error: String?
    @State private var saving = false
    @State private var adding = false
    @State private var removing: CantripPolicySnapshot.Rule?

    var body: some View {
        Form {
            Section { SettingsScopeLabel.allTabs(on: remote.macName) }
            if let snapshot {
                Section {
                    Toggle("Check every tab against the policy", isOn: Binding(
                        get: { snapshot.policy.enabled },
                        set: { value in save(["enabled": value]) }
                    ))
                    .accessibilityIdentifier("policy.enabled")
                } footer: {
                    Text("Every tab, child tab and Home run checks each tool call against these rules, on every backend. Deny beats ask and ask beats allow; anything no rule covers runs when Act on my behalf is on and asks when it's off.")
                }
                ForEach(CantripPolicySnapshot.effects, id: \.self) { effect in
                    let rules = snapshot.policy.rules.filter { $0.effect == effect }
                    if !rules.isEmpty {
                        Section("\(CantripPolicySnapshot.heading(effect)) (\(rules.count))") {
                            ForEach(rules) { rule in row(rule, summary: snapshot.summaries[rule.id]) }
                        }
                    }
                }
                Section {
                    Button("Add a Rule", systemImage: "plus.circle") { adding = true }
                        .accessibilityIdentifier("policy.add")
                }
                if let projects = snapshot.policy.projects, !projects.isEmpty {
                    Section("Project overrides") {
                        ForEach(projects, id: \.path) { project in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.path).font(.subheadline.monospaced())
                                if let disabled = project.disabled, !disabled.isEmpty {
                                    Text("Turned off here: " + disabled.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                                }
                                ForEach(project.rules ?? []) { rule in
                                    Text("\(CantripPolicySnapshot.label(rule.effect)): \(rule.id) — \(snapshot.summaries[rule.id] ?? "")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if let conflicts = snapshot.policy.conflicts, !conflicts.isEmpty {
                    Section("Imported rules a stricter rule overrides") {
                        ForEach(Array(conflicts.enumerated()), id: \.offset) { _, conflict in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(conflict.imported) → \(conflict.stricter)").font(.subheadline)
                                Text(conflict.note).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    LabeledContent("Saved in", value: snapshot.file)
                } footer: {
                    Text("Imports and each CLI's own deny lists stay under Cantrip's control on the Mac.")
                }
            } else if error == nil {
                Section { ProgressView() }
            }
            if let message = error ?? snapshot?.loadError {
                Section { Label(message, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            }
        }
        .formStyle(.grouped)
        .disabled(saving)
        .navigationTitle("Agent policy")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $adding) {
            SettingsPolicyRuleSheet { rule in
                adding = false
                save(["rule": rule])
            }
        }
        .confirmationDialog("Remove \(removing?.id ?? "")?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let rule = removing { save(["removeRule": rule.id]) }
                removing = nil
            }
        }
    }

    private func row(_ rule: CantripPolicySnapshot.Rule, summary: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { rule.enabled },
                set: { value in save(["setRuleEnabled": ["id": rule.id, "enabled": value]]) }
            )) {
                Text(rule.id).font(.body.monospaced())
            }
            if !rule.reason.isEmpty { Text(rule.reason).font(.caption).fixedSize(horizontal: false, vertical: true) }
            if let summary, !summary.isEmpty {
                Text(summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Menu(CantripPolicySnapshot.label(rule.effect)) {
                    ForEach(CantripPolicySnapshot.effects, id: \.self) { effect in
                        Button(CantripPolicySnapshot.label(effect)) { changeEffect(rule, to: effect) }
                            .disabled(effect == rule.effect)
                    }
                }
                .accessibilityLabel("Effect: \(CantripPolicySnapshot.label(rule.effect))")
                if let source = rule.importedFrom {
                    Text("From \(source)").font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer()
                Button("Remove", role: .destructive) { removing = rule }
                    .accessibilityLabel("Remove \(rule.id)")
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .opacity(rule.enabled ? 1 : 0.6)
    }

    private func changeEffect(_ rule: CantripPolicySnapshot.Rule, to effect: String) {
        var raw = rule.raw
        raw["effect"] = .string(effect)
        guard let data = try? JSONEncoder().encode(MCPAppJSONValue.object(raw)),
              let object = try? JSONSerialization.jsonObject(with: data) else { return }
        save(["rule": object])
    }

    private func load() async {
        do {
            snapshot = try await remote.agentPolicy()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save(_ change: [String: Any]) {
        guard let revision = snapshot?.policy.revision else { return }
        saving = true
        Task {
            defer { saving = false }
            var body = change
            body["revision"] = revision
            if let updated = await remote.updateAgentPolicy(body) {
                snapshot = updated
                error = nil
            } else {
                error = remote.errorMessage ?? "That didn't save."
                await load()
            }
        }
    }
}

/// A new Mac-wide rule: what it matches (comma-separated lists) and what happens.
private struct SettingsPolicyRuleSheet: View {
    let add: ([String: Any]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var id = ""
    @State private var effect = "deny"
    @State private var reason = ""
    @State private var commands = ""
    @State private var paths = ""
    @State private var mcp = ""
    @State private var hours = ""
    @State private var repos = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("ID (no-release-on-fridays)", text: $id)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    Picker("Effect", selection: $effect) {
                        ForEach(CantripPolicySnapshot.effects, id: \.self) { Text(CantripPolicySnapshot.label($0)).tag($0) }
                    }
                    TextField("Reason, shown to the agent and on approval cards", text: $reason, axis: .vertical)
                }
                Section {
                    field("Commands (git push, re:…, @cantrip-restart)", $commands)
                    field("Paths ($WORKTREE, $PROJECT, $TMP, ~)", $paths)
                    field("MCP tools (server/tool, server/*)", $mcp)
                    field("Hours (21:45-22:50)", $hours)
                    field("Only in repositories", $repos)
                } header: {
                    Text("Matches")
                } footer: {
                    Text("Comma-separated. A rule applies when a tool call matches what it names.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add a Rule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add(rule) }
                        .disabled(id.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 480)
        #endif
    }

    private func field(_ prompt: String, _ text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
    }

    private var rule: [String: Any] {
        func list(_ text: String) -> [String]? {
            let values = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return values.isEmpty ? nil : values
        }
        var rule: [String: Any] = ["id": id.trimmingCharacters(in: .whitespaces), "effect": effect,
                                   "reason": reason.trimmingCharacters(in: .whitespacesAndNewlines), "source": "user"]
        for (key, text) in [("commands", commands), ("paths", paths), ("mcp", mcp), ("hours", hours), ("repos", repos)] {
            if let values = list(text) { rule[key] = values }
        }
        return rule
    }
}

struct SettingsSecretsPage: View {
    @ObservedObject var remote: CantripRemoteModel
    @State private var snapshot: CantripSecretsSnapshot?
    @State private var error: String?
    @State private var syncing = false

    var body: some View {
        Form {
            Section { SettingsScopeLabel.allTabs(on: remote.macName) }
            if let snapshot {
                Section {
                    LabeledContent("Secrets", value: snapshot.status())
                    if snapshot.syncing == true {
                        Label("Waiting for the password on the Mac…", systemImage: "hourglass").foregroundStyle(.secondary)
                    } else {
                        Button("Unlock & Sync", systemImage: "arrow.triangle.2.circlepath") { sync() }
                            .disabled(syncing || snapshot.available == false)
                            .accessibilityIdentifier("secrets.sync")
                    }
                    if snapshot.available == false {
                        Text("Install the Bitwarden CLI on the Mac (brew install bitwarden-cli) and log in once with `bw login`.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if let report = snapshot.lastReport { Text(report).font(.caption).foregroundStyle(.secondary) }
                    if let failure = snapshot.lastError { Text(failure).font(.caption).foregroundStyle(.orange) }
                } footer: {
                    Text("Bitwarden's “\(snapshot.folder)” folder is the source; the Mac keeps a copy in its Keychain so scheduled jobs work while the vault is locked. Sync asks for the vault password on the Mac itself. Commands get values with `cantrip secret run NAME -- command`; models and paired devices only see names.")
                }
                if !snapshot.items.isEmpty {
                    Section("By name") {
                        ForEach(snapshot.items) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).font(.body.monospaced())
                                Text(item.kind == "fields" ? item.fields.joined(separator: " ") : item.kind)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let skipped = snapshot.skipped, !skipped.isEmpty {
                    Section("Skipped") {
                        ForEach(skipped, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                    }
                }
            } else if error == nil {
                Section { ProgressView() }
            }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Secrets")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await load()
            // While the Mac waits for its password, follow the sync to its end.
            while !Task.isCancelled, snapshot?.syncing == true {
                try? await Task.sleep(for: .seconds(2))
                await load()
            }
        }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            snapshot = try await remote.secrets()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func sync() {
        syncing = true
        Task {
            defer { syncing = false }
            if let updated = await remote.syncSecrets() {
                snapshot = updated
                while !Task.isCancelled, snapshot?.syncing == true {
                    try? await Task.sleep(for: .seconds(2))
                    await load()
                }
            } else {
                error = remote.errorMessage ?? "The sync didn't start."
            }
        }
    }
}
