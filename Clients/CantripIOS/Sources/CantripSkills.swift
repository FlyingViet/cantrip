import SwiftUI

/// `GET/POST /api/v1/skills`: the one skills library Cantrip gives every backend, the folder rules
/// it mirrors, and the rules drift check. Mac-wide, not per tab; skills are edited on the Mac.
struct CantripSkillsSnapshot: Decodable, Equatable {
    var library: String
    var backends: [String]
    var skills: [CantripSkill]
    var rules: [CantripSkillsRule]
    var drift: [CantripSkillsDrift]
    /// ISO 8601; nil until the drift check has run.
    var driftCheckedAt: String?
    var checking: Bool
    /// What a relink (`sync`) changed.
    var messages: [String]?

    private enum CodingKeys: String, CodingKey {
        case library, backends, skills, rules, drift, driftCheckedAt, checking, messages
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        skills = try container.decode([CantripSkill].self, forKey: .skills)
        library = try container.decodeIfPresent(String.self, forKey: .library) ?? ""
        backends = try container.decodeIfPresent([String].self, forKey: .backends) ?? []
        rules = try container.decodeIfPresent([CantripSkillsRule].self, forKey: .rules) ?? []
        drift = try container.decodeIfPresent([CantripSkillsDrift].self, forKey: .drift) ?? []
        driftCheckedAt = try container.decodeIfPresent(String.self, forKey: .driftCheckedAt)
        checking = try container.decodeIfPresent(Bool.self, forKey: .checking) ?? false
        messages = try container.decodeIfPresent([String].self, forKey: .messages)
    }

    var driftCheckedDate: Date? { driftCheckedAt.flatMap(CantripSkills.date) }
}

struct CantripSkill: Decodable, Equatable, Identifiable {
    var id: String { name }
    var name: String
    var description: String
    var enabled: Bool
    /// The backends that see it now.
    var backends: [String]
    var problems: [String]

    private enum CodingKeys: String, CodingKey { case name, description, enabled, backends, problems }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        backends = try container.decodeIfPresent([String].self, forKey: .backends) ?? []
        problems = try container.decodeIfPresent([String].self, forKey: .problems) ?? []
    }
}

struct CantripSkillsRule: Decodable, Equatable, Identifiable {
    var id: String { folder }
    var folder: String
    var lines: Int
    var mirror: String?
}

struct CantripSkillsDrift: Decodable, Equatable, Identifiable {
    var id: String { path + "\n" + problem }
    var path: String
    var problem: String
}

/// The POST body.
enum CantripSkillsAction: Encodable, Equatable {
    /// On or off for every backend.
    case setEnabled(name: String, enabled: Bool)
    /// Relink everything.
    case sync
    /// Start the rules drift check.
    case check

    private enum CodingKeys: String, CodingKey { case action, name, enabled }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .setEnabled(let name, let enabled):
            try container.encode("setEnabled", forKey: .action)
            try container.encode(name, forKey: .name)
            try container.encode(enabled, forKey: .enabled)
        case .sync:
            try container.encode("sync", forKey: .action)
        case .check:
            try container.encode("check", forKey: .action)
        }
    }
}

/// The screen's words and timing, shared by every client (Windows ports them in `sheetLogic.ts`).
enum CantripSkills {
    static let title = "Skills & Rules"
    static let explainer = "Cantrip keeps one skills library and gives every backend the same skills and folder rules. Edit skills on the Mac (`cantrip skills edit NAME`)."
    static let unsupported = "This Mac's Cantrip doesn't share skills yet. Update Cantrip on the Mac."

    /// Every ~2 s while the drift check runs, otherwise no faster than every ~10 s.
    static func pollInterval(checking: Bool) -> Duration { .seconds(checking ? 2 : 10) }

    static func seenBy(_ skill: CantripSkill) -> String {
        skill.backends.isEmpty ? "No backend sees it" : "Seen by: " + skill.backends.joined(separator: ", ")
    }

    static func toggleLabel(_ skill: CantripSkill) -> String {
        "\(skill.name), \(skill.enabled ? "on" : "off") for every backend"
    }

    static func ruleText(_ rule: CantripSkillsRule) -> String {
        let text = "\(rule.folder) — \(rule.lines) \(rule.lines == 1 ? "line" : "lines")"
        guard let mirror = rule.mirror, !mirror.isEmpty else { return text }
        return text + " (mirrored to \(mirror))"
    }

    static func driftStatus(_ snapshot: CantripSkillsSnapshot, now: Date = Date(),
                            locale: Locale = .autoupdatingCurrent) -> String {
        if snapshot.checking { return "Checking…" }
        guard let checked = snapshot.driftCheckedDate else { return "Not checked yet" }
        return "Last checked " + relative(checked, now: now, locale: locale)
    }

    /// Drift was checked and found nothing.
    static func isDriftClear(_ snapshot: CantripSkillsSnapshot) -> Bool {
        !snapshot.checking && snapshot.drift.isEmpty && snapshot.driftCheckedAt != nil
    }

    static func relinkSummary(_ messages: [String]) -> String {
        messages.isEmpty ? "Relinked. Everything was already linked." : "Relinked: " + messages.joined(separator: ". ")
    }

    static func driftSummary(_ snapshot: CantripSkillsSnapshot) -> String {
        switch snapshot.drift.count {
        case 0: return "No drift found"
        case 1: return "1 drift finding"
        case let count: return "\(count) drift findings"
        }
    }

    static func relative(_ date: Date, now: Date, locale: Locale = .autoupdatingCurrent) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}

/// Skills & Rules: switch each library skill on or off for every backend, relink, see the folder
/// rules and check them for drift. Skills themselves are edited on the Mac.
struct CantripSkillsView: View {
    @ObservedObject var remote: CantripRemoteModel
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: CantripSkillsSnapshot?
    @State private var error: String?
    @State private var unsupported = false
    @State private var working: String?
    @State private var relinked: [String]?
    @State private var now = Date()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(LocalizedStringKey(CantripSkills.explainer))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error {
                    Section { CantripSkillsWarning(text: error) }
                }
                if let snapshot {
                    skillsSection(snapshot)
                    relinkSection
                    rulesSection(snapshot)
                    driftSection(snapshot)
                } else if error == nil {
                    Section { ProgressView("Loading skills…").frame(maxWidth: .infinity, minHeight: 44) }
                }
            }
            .navigationTitle(CantripSkills.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task(id: [snapshot?.checking == true, unsupported]) { await poll() }
            .refreshable { await load() }
            .onChange(of: error) { _, message in
                if let message { AccessibilityNotification.Announcement("Warning: \(message)").post() }
            }
            .onChange(of: snapshot?.checking) { was, checking in
                if was == true, checking == false, let snapshot {
                    AccessibilityNotification.Announcement(CantripSkills.driftSummary(snapshot)).post()
                }
            }
        }
    }

    private func skillsSection(_ snapshot: CantripSkillsSnapshot) -> some View {
        Section {
            if snapshot.skills.isEmpty {
                Text("The library has no skills yet.").foregroundStyle(.secondary)
            }
            ForEach(snapshot.skills) { skill in
                CantripSkillRow(skill: skill, isDisabled: working != nil) { enabled in
                    setEnabled(skill, enabled)
                }
            }
        } header: {
            Text("Skills")
        } footer: {
            if !snapshot.library.isEmpty { Text("Library: \(snapshot.library)") }
        }
    }

    private var relinkSection: some View {
        Section {
            Button { act(.sync, name: "sync") } label: {
                HStack {
                    Label("Relink", systemImage: "link")
                    if working == "sync" { Spacer(); ProgressView() }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .disabled(working != nil)
            .accessibilityHint("Links every skill into every backend again")
            .accessibilityIdentifier("skills.relink")
            if let relinked {
                if relinked.isEmpty {
                    Text("Everything was already linked.").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(Array(relinked.enumerated()), id: \.offset) { _, message in
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func rulesSection(_ snapshot: CantripSkillsSnapshot) -> some View {
        Section("Folder rules") {
            if snapshot.rules.isEmpty {
                Text("No folder rules yet.").foregroundStyle(.secondary)
            }
            ForEach(snapshot.rules) { rule in
                Text(CantripSkills.ruleText(rule)).font(.subheadline)
            }
        }
    }

    private func driftSection(_ snapshot: CantripSkillsSnapshot) -> some View {
        Section("Drift") {
            ForEach(snapshot.drift) { finding in
                VStack(alignment: .leading, spacing: 4) {
                    Text(finding.path).font(.subheadline.monospaced())
                    CantripSkillsWarning(text: finding.problem)
                }
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                .accessibilityElement(children: .combine)
            }
            if CantripSkills.isDriftClear(snapshot) {
                Label("No drift found", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if snapshot.checking { ProgressView().accessibilityHidden(true) }
                Text(CantripSkills.driftStatus(snapshot, now: now))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button { act(.check, name: "check") } label: {
                Label("Check now", systemImage: "checklist")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .disabled(working != nil || snapshot.checking)
            .accessibilityHint("Checks every folder's rules files for drift")
            .accessibilityIdentifier("skills.check")
        }
    }

    private func setEnabled(_ skill: CantripSkill, _ enabled: Bool) {
        if let index = snapshot?.skills.firstIndex(where: { $0.name == skill.name }) {
            snapshot?.skills[index].enabled = enabled
        }
        act(.setEnabled(name: skill.name, enabled: enabled), name: "skill:" + skill.name)
    }

    private func act(_ action: CantripSkillsAction, name: String) {
        working = name
        Task {
            defer { working = nil }
            if let updated = await remote.skillsAction(action) {
                snapshot = updated
                now = Date()
                error = nil
                if action == .sync {
                    relinked = updated.messages ?? []
                    AccessibilityNotification.Announcement(CantripSkills.relinkSummary(updated.messages ?? [])).post()
                    clearRelinked(after: relinked)
                }
            } else {
                error = remote.errorMessage ?? "That didn't go through."
                await load(keepingError: true)
            }
        }
    }

    /// Relink's messages show briefly.
    private func clearRelinked(after shown: [String]?) {
        Task {
            try? await Task.sleep(for: .seconds(8))
            if relinked == shown { relinked = nil }
        }
    }

    private func load(keepingError: Bool = false) async {
        do {
            snapshot = try await remote.skills()
            now = Date()
            unsupported = false
            if !keepingError { error = nil }
        } catch CantripRemoteError.skillsUnsupported {
            unsupported = true
            error = CantripSkills.unsupported
        } catch is CancellationError {
        } catch {
            if !keepingError { self.error = error.localizedDescription }
        }
    }

    /// Loads on open, then every ~2 s while the drift check runs and every ~10 s otherwise.
    /// Restarts when `checking` changes; stops for a Mac too old to share skills (until a
    /// pull to refresh finds it updated).
    private func poll() async {
        if snapshot == nil, !unsupported { await load() }
        while !Task.isCancelled, !unsupported {
            try? await Task.sleep(for: CantripSkills.pollInterval(checking: snapshot?.checking == true))
            guard !Task.isCancelled else { return }
            if working == nil { await load() }
        }
    }
}

private struct CantripSkillRow: View {
    let skill: CantripSkill
    let isDisabled: Bool
    let setEnabled: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { skill.enabled }, set: setEnabled)) {
                Text(skill.name).font(.body.monospaced())
            }
            .frame(minHeight: 44)
            .disabled(isDisabled)
            .accessibilityLabel(CantripSkills.toggleLabel(skill))
            .accessibilityIdentifier("skills.toggle.\(skill.name)")
            if !skill.description.isEmpty {
                Text(skill.description).font(.subheadline).foregroundStyle(.secondary)
            }
            Text(CantripSkills.seenBy(skill)).font(.footnote).foregroundStyle(.secondary)
            ForEach(Array(skill.problems.enumerated()), id: \.offset) { _, problem in
                CantripSkillsWarning(text: problem)
            }
        }
        .padding(.vertical, 2)
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
    }
}

/// A warning line: icon and "Warning:" for VoiceOver, never color alone.
struct CantripSkillsWarning: View {
    let text: String

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").accessibilityHidden(true)
        }
        .font(.footnote)
        .foregroundStyle(.orange)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Warning: \(text)")
    }
}
