import SwiftUI

/// Agent policy › Privacy Gate: whether Cantrip Home's chat and scheduled tasks are checked, in which
/// mode, the classifier it asks, Home chat's and each task's own route, and the fixed rules. Each
/// change goes through the page's `save` (with the revision it read), so errors show like the rest.
struct SettingsPrivacyGateSections: View {
    @ObservedObject var remote: CantripRemoteModel
    let gate: CantripPrivacyGate
    let classifier: CantripPrivacyClassifierStatus?
    /// Home's scheduled tasks, for their routes.
    let tasks: [CantripHomeTask]
    let save: ([String: Any]) -> Void
    @State private var testing = false
    @State private var testResult: CantripPrivacyTestResult?
    @State private var testError: String?

    init(remote: CantripRemoteModel, gate: CantripPrivacyGate, classifier: CantripPrivacyClassifierStatus?,
         tasks: [CantripHomeTask], testResult: CantripPrivacyTestResult? = nil,
         save: @escaping ([String: Any]) -> Void) {
        self.remote = remote
        self.gate = gate
        self.classifier = classifier
        self.tasks = tasks
        self.save = save
        _testResult = State(initialValue: testResult)
    }

    var body: some View {
        switchSection
        classifierSection
        routesSection
        rulesSection
    }

    private var switchSection: some View {
        Section {
            SettingsScopeLabel(text: "Cantrip Home on \(remote.macName)", systemImage: "house")
            Toggle("Privacy Gate", isOn: Binding(
                get: { gate.enabled },
                set: { save(gate.setting("enabled", to: .bool($0)).change) }
            ))
            .accessibilityIdentifier("privacyGate.enabled")
            Picker("Mode", selection: Binding(
                get: { gate.mode },
                set: { save(gate.setting("mode", to: .string($0.rawValue)).change) }
            )) {
                ForEach(CantripPrivacyGate.Mode.allCases) { mode in
                    SettingsPrivacyModeRow(mode: mode).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .accessibilityIdentifier("privacyGate.mode")
        } header: {
            Text("Privacy Gate")
        } footer: {
            Text("Decides for each Home chat message and scheduled Home task whether it runs on your own model server, in the cloud, or asks you first.")
        }
    }

    private var classifierSection: some View {
        Section {
            SettingsPrivacyClassifierRow(status: classifier)
            Button(action: test) {
                Label(testing ? "Testing…" : "Test connection", systemImage: "bolt.horizontal")
            }
            .disabled(testing)
            .accessibilityIdentifier("privacyGate.test")
            if let testResult {
                Label(testResult.summary, systemImage: testResult.ok ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(testResult.ok ? Color.secondary : Color.orange)
                    .accessibilityIdentifier("privacyGate.testResult")
            } else if let testError {
                Label(testError, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Classifier")
        } footer: {
            Text("A model on your own server reads what each rule leaves undecided and says where it belongs. Test connection asks it one made-up coding question.")
        }
    }

    private var routesSection: some View {
        Section {
            routePicker("Home chat", selection: gate.chat, task: nil)
                .accessibilityIdentifier("privacyGate.route.chat")
            ForEach(tasks) { task in
                routePicker(task.title.isEmpty ? "Untitled task" : task.title, selection: gate.route(forTask: task.id), task: task.id)
            }
        } header: {
            Text("Routes")
        } footer: {
            Text(tasks.isEmpty
                 ? "Decide each time lets the Privacy Gate choose. Scheduled Home tasks show here once Home has some."
                 : "Decide each time lets the Privacy Gate choose; a fixed route skips it for Home chat or that task.")
        }
    }

    private var rulesSection: some View {
        Section {
            ForEach(gate.rules) { rule in
                SettingsPrivacyRuleRow(rule: rule) { enabled in
                    save(gate.settingRule(rule.id, enabled: enabled).change)
                }
            }
        } header: {
            Text("Privacy rules (\(gate.rules.count))")
        } footer: {
            Text("Rules decide before the classifier: the first rule that's on and matches wins.")
        }
    }

    private func routePicker(_ title: String, selection: CantripPrivacyRouteChoice, task: UUID?) -> some View {
        Picker(title, selection: Binding(
            get: { selection },
            set: { save(CantripPrivacyGate.routeChange(task: task, route: $0)) }
        )) {
            ForEach(CantripPrivacyRouteChoice.allCases) { Text($0.label).tag($0) }
        }
    }

    private func test() {
        testing = true
        testResult = nil
        testError = nil
        Task {
            defer { testing = false }
            if let result = await remote.testPrivacyClassifier() {
                testResult = result
            } else {
                testError = remote.errorMessage ?? "The Mac didn't answer."
            }
        }
    }
}

private struct SettingsPrivacyModeRow: View {
    let mode: CantripPrivacyGate.Mode

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(mode.title)
            Text(mode.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Same server as Private Local", the classifier's own address and model, or why there's none.
private struct SettingsPrivacyClassifierRow: View {
    let status: CantripPrivacyClassifierStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(status?.headline ?? "This Mac didn't say where its classifier is.",
                  systemImage: status?.isConfigured == true ? "cpu" : "exclamationmark.triangle")
                .foregroundStyle(status?.isConfigured == true ? Color.primary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle = status?.subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("privacyGate.classifier")
    }
}

private struct SettingsPrivacyRuleRow: View {
    let rule: CantripPrivacyGate.Rule
    let setEnabled: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { rule.enabled }, set: setEnabled)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.id).font(.body.monospaced())
                Text(rule.matches.isEmpty ? rule.routeTitle : "\(rule.routeTitle) · \(rule.matches)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("privacyGate.rule.\(rule.id)")
    }
}
