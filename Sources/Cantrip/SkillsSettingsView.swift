import AppKit
import SwiftUI

/// Settings > Skills & Rules: Cantrip's skills library (which backends see each skill, on/off,
/// problems) and the folder rules every backend gets, with drift in the repositories' rule files.
struct SkillsSettingsView: View {
    @ObservedObject var hub = SkillsHub.shared
    @ObservedObject var settings = AppSettings.shared
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Skills & Rules").font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                Button("Open Library") { open(SkillsLibrary().folder) }
                    .help("Edit skills here; every backend reads them through links")
                Button("Relink") { run { try hub.sync() } }
                    .help("Link every skill that's on for every backend, and unlink the ones that are off")
            }
            .font(.caption)
            Text("One skills library for every backend: Copilot, Codex and Antigravity read ~/.agents/skills, Claude Code ~/.claude/skills; both link here. Edit in the library or with `cantrip skills edit NAME`.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Link new skills automatically", isOn: $settings.skillsAutoLink)
                .font(.caption)
                .toggleStyle(.checkbox)
                .help("A skill added, changed or removed in the library is linked for every backend about a minute later, as Relink does")
            if let error { Text(error).font(.caption2).foregroundStyle(.orange).accessibilityLabel("Error: \(error)") }
            if !hub.messages.isEmpty {
                Text(hub.messages.joined(separator: "\n")).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if hub.skills.isEmpty {
                Text("No skills yet. Add one with `cantrip skills add PATH`.").font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(hub.skills, id: \.name) { skill in
                SkillRow(skill: skill) { on in run { try hub.setEnabled(skill.name, on) } }
            }

            HStack {
                Text("Folder rules").font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                Button("Open Rules") { open(FolderInstructions().folder) }
                    .help("Rules for everything under a folder; edit with `cantrip instructions edit FOLDER`")
                Button(hub.checking ? "Checking…" : "Check for Drift") { hub.checkDrift() }
                    .disabled(hub.checking)
                    .help("Missing AGENTS.md files, CLAUDE.md pointers with their own rules, and personal details in public repositories")
            }
            .font(.caption)
            .padding(.top, 4)
            if hub.rules.isEmpty {
                Text("No folder rules. Add some with `cantrip instructions edit FOLDER`.").font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(hub.rules, id: \.folder) { rule in
                let lines = rule.body.isEmpty ? 0 : rule.body.components(separatedBy: "\n").count
                let mirror = rule.mirror.map { " · mirrored to \(FolderInstructions().tilde($0))" } ?? ""
                Text("\(FolderInstructions().tilde(rule.folder)) — \(lines) line\(lines == 1 ? "" : "s")\(mirror)")
                    .font(.caption2).textSelection(.enabled)
            }
            if let checked = hub.driftCheckedAt {
                Text(hub.drift.isEmpty ? "No drift found (checked \(checked.formatted(date: .omitted, time: .shortened)))."
                     : "Drift (checked \(checked.formatted(date: .omitted, time: .shortened))):")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(Array(hub.drift.enumerated()), id: \.offset) { _, finding in
                Label { Text("\(finding.path): \(finding.problem)").font(.caption2).textSelection(.enabled) }
                    icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Warning: \(finding.path), \(finding.problem)")
            }
        }
        .onAppear { hub.refresh() }
    }

    private func run(_ action: () throws -> Void) {
        do {
            try action()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func open(_ folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}

private struct SkillRow: View {
    let skill: SkillsLibrary.Status
    let setEnabled: (Bool) -> Void

    private var seen: String {
        skill.backends.isEmpty ? "No backend sees it" : "Seen by \(skill.backends.joined(separator: ", "))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Toggle(isOn: Binding(get: { skill.enabled }, set: setEnabled)) {
                    Text(skill.name).font(.caption.weight(.medium))
                }
                .toggleStyle(.checkbox)
                .accessibilityLabel("\(skill.name), \(skill.enabled ? "on" : "off"). \(seen)")
                Spacer(minLength: 0)
                Text(seen).font(.caption2).foregroundStyle(skill.problems.isEmpty ? Color.secondary : Color.orange)
            }
            if !skill.description.isEmpty {
                Text(skill.description).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            ForEach(skill.problems, id: \.self) { problem in
                Label { Text(problem).font(.caption2) } icon: { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Warning: \(problem)")
            }
        }
        .padding(.vertical, 2)
    }
}
