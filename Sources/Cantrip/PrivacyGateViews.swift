import AppKit
import SwiftUI

/// The Privacy Gate's route under a Home request: what it decided (or would decide, observing).
struct PrivacyBadgeLine: View {
    let badge: PrivacyBadge

    private var symbol: String {
        switch badge.route {
        case "local": return "house.fill"
        case "cloud": return "cloud"
        case "redactApprove": return "eye.slash"
        default: return "wifi.slash"
        }
    }

    var body: some View {
        Label(badge.label, systemImage: symbol)
            .font(.caption2)
            .foregroundStyle(badge.mode == "enforce" && badge.route == "local" ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            .help(badge.detail)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Privacy: \(badge.label)")
            .accessibilityHint(badge.detail)
    }
}

/// Settings › Agent policy › Privacy Gate: observe or enforce, the classifier, Home chat's and each
/// task's own route, and the rules.
struct PrivacyGateSettingsView: View {
    let settings: PrivacyGateSettings
    let save: ((inout PrivacyGateSettings) -> Void) -> Void
    @State private var testing = false
    @State private var testResult: String?
    @State private var showRules = false
    @State private var showTasks = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Check Home chat and Home tasks before they reach a cloud model", isOn: binding(\.enabled))
                .toggleStyle(.checkbox).font(.caption)
            Picker("Mode", selection: binding(\.mode)) {
                Text("Observe").tag(PrivacyGateMode.observe)
                Text("Enforce").tag(PrivacyGateMode.enforce)
            }
            .pickerStyle(.segmented).frame(maxWidth: 240).font(.caption)
            .disabled(!settings.enabled)
            Text(settings.mode == .observe
                 ? "Observe records where each request would run and changes nothing: same backend, prompt and tools."
                 : "Enforce runs private requests on your own model, asks before sending personal details, and takes private tools and folders away from cloud runs.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            classifier
            HStack {
                Text("Home chat").font(.caption)
                Spacer()
                routePicker(settings.chat) { value in save { $0.chat = value } }
            }
            DisclosureGroup(isExpanded: $showTasks) {
                VStack(alignment: .leading, spacing: 3) {
                    let tasks = CantripHomeStore.shared.tasks
                    if tasks.isEmpty { Text("No scheduled tasks.").font(.caption2).foregroundStyle(.secondary) }
                    ForEach(tasks, id: \.id) { task in
                        HStack {
                            Text(task.title).font(.caption2).lineLimit(1)
                            Spacer()
                            routePicker(settings.tasks[task.id.uuidString] ?? .auto) { value in
                                save { $0.tasks[task.id.uuidString] = value == .auto ? nil : value }
                            }
                        }
                    }
                }
                .padding(.top, 2)
            } label: {
                Text("Scheduled tasks (\(settings.tasks.count) with their own route)").font(.caption)
            }
            DisclosureGroup(isExpanded: $showRules) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(settings.rules) { rule in
                        Toggle(isOn: Binding(
                            get: { rule.enabled },
                            set: { value in save { gate in
                                if let index = gate.rules.firstIndex(where: { $0.id == rule.id }) { gate.rules[index].enabled = value }
                            } }
                        )) {
                            Text("\(rule.id) → \(rule.route.label.lowercased())").font(.caption2)
                        }
                        .toggleStyle(.checkbox)
                    }
                    Text("First match wins, after Home chat's or the task's own route. Requests no rule decides go to the classifier; it says cloud only when it's at least \(Int(settings.classifier.cloudMinProbability * 100))% sure.")
                        .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            } label: {
                Text("Rules (\(settings.rules.filter(\.enabled).count) on)").font(.caption)
            }
            Text("Decisions are logged on this Mac without prompt text: \(PrivacyGate.shared.classifierStatus(settings).log). Run `cantrip privacy report` for a summary.")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private var classifier: some View {
        let status = PrivacyGate.shared.classifierStatus(settings)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("Classifier").font(.caption)
                Spacer()
                Button(testing ? "Testing…" : "Test Connection") {
                    testing = true
                    testResult = nil
                    Task {
                        let result = await PrivacyGate.shared.testClassifier(settings)
                        testing = false
                        testResult = result.ok
                            ? "Answered \(result.route ?? "?") in \(result.latencyMs ?? 0) ms (cloud \(Int(((result.probabilities?["cloud"]) ?? 0) * 100))%)."
                            : (result.error ?? "No answer.")
                    }
                }
                .controlSize(.small).disabled(testing || status.address == nil)
            }
            Text(status.address.map { "\(status.model ?? "") at \($0)" + (status.from == "privateLocal" ? " (Private Local's server)" : "") }
                 ?? (status.problem ?? "Not set up."))
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let testResult {
                Text(testResult).font(.caption2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func routePicker(_ value: PrivacyRouteOverride, set: @escaping (PrivacyRouteOverride) -> Void) -> some View {
        Picker("", selection: Binding(get: { value }, set: set)) {
            ForEach(PrivacyRouteOverride.allCases, id: \.self) { route in Text(route.label).tag(route) }
        }
        .labelsHidden().controlSize(.small).frame(maxWidth: 230)
    }

    private func binding<Value>(_ path: WritableKeyPath<PrivacyGateSettings, Value>) -> Binding<Value> {
        Binding(get: { settings[keyPath: path] }, set: { value in save { $0[keyPath: path] = value } })
    }
}
