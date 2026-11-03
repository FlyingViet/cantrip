import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// One Settings page's share of the Mac's settings (`CantripSettingsManifest`), as Form sections.
/// Pages place it where it belongs; `fallback` shows when the Mac has no settings manifest (an
/// older Cantrip) or it hasn't loaded.
struct SettingsManifestSections<Fallback: View>: View {
    let page: String
    let fallback: Fallback
    @Environment(\.cantripSettings) private var store

    init(page: String, @ViewBuilder fallback: () -> Fallback) {
        self.page = page
        self.fallback = fallback()
    }

    var body: some View {
        if let store {
            SettingsManifestPageBody(store: store, page: page, fallback: fallback)
        } else {
            fallback
        }
    }
}

extension SettingsManifestSections where Fallback == EmptyView {
    init(page: String) {
        self.init(page: page) { EmptyView() }
    }
}

private struct SettingsManifestPageBody<Fallback: View>: View {
    @ObservedObject var store: CantripSettingsStore
    let page: String
    let fallback: Fallback

    var body: some View {
        if let manifest = store.manifest, let page = manifest.page(page) {
            if let pending = manifest.pending, Self.owns(page, pending) {
                SettingsPendingSection(store: store, pending: pending)
            }
            ForEach(Self.groups(page.sections)) { group in
                if group.links {
                    Section {
                        ForEach(group.sections) { section in
                            NavigationLink {
                                SettingsManifestLinkPage(store: store, pageID: page.id, sectionID: section.id)
                            } label: {
                                LabeledContent(section.title, value: section.summary ?? "")
                            }
                            .accessibilityIdentifier("settings.section.\(section.id)")
                        }
                    }
                } else if let section = group.sections.first {
                    SettingsManifestSectionView(store: store, manifest: manifest, section: section)
                }
            }
        } else {
            fallback
            if store.manifest == nil, let error = store.loadError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    Button("Retry") { Task { await store.load(force: true) } }
                        .disabled(store.isLoading)
                }
            }
        }
    }

    /// The waiting change shows on the page whose setting it is (the token's on Macs).
    static func owns(_ page: CantripSettingsManifest.Page, _ pending: CantripSettingsManifest.Pending) -> Bool {
        page.sections.contains { $0.fields.contains { pending.keys.contains($0.key) } }
            || (page.id == "macs" && pending.keys.contains("pairingToken"))
    }

    struct Group: Identifiable {
        let id: String
        let links: Bool
        let sections: [CantripSettingsManifest.Section]
    }

    /// Sections drawn inline, each on its own; screens of their own (`link`) share one section of rows.
    static func groups(_ sections: [CantripSettingsManifest.Section]) -> [Group] {
        var groups: [Group] = []
        for section in sections {
            if section.link == true, let last = groups.last, last.links {
                groups[groups.count - 1] = Group(id: last.id, links: true, sections: last.sections + [section])
            } else {
                groups.append(Group(id: section.id, links: section.link == true, sections: [section]))
            }
        }
        return groups
    }
}

/// A section opened as its own screen (each backend's settings, the CLI paths, the simulator pool).
struct SettingsManifestLinkPage: View {
    @ObservedObject var store: CantripSettingsStore
    let pageID: String
    let sectionID: String

    var body: some View {
        Form {
            if let manifest = store.manifest,
               let section = manifest.page(pageID)?.sections.first(where: { $0.id == sectionID }) {
                SettingsManifestSectionView(store: store, manifest: manifest, section: section, showsHeader: false)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(store.manifest?.page(pageID)?.sections.first { $0.id == sectionID }?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SettingsManifestSectionView: View {
    @ObservedObject var store: CantripSettingsStore
    let manifest: CantripSettingsManifest
    let section: CantripSettingsManifest.Section
    var showsHeader = true

    var body: some View {
        let fields = manifest.visibleFields(section)
        if !fields.isEmpty {
            Section {
                ForEach(fields) { field in
                    SettingsManifestFieldRow(store: store, field: field)
                }
            } header: {
                if showsHeader { Text(section.title) }
            } footer: {
                if let footer = section.footer { Text(footer) }
            }
        }
    }
}

/// One setting: its control, what it does, and why it's read-only or didn't save.
struct SettingsManifestFieldRow: View {
    @ObservedObject var store: CantripSettingsStore
    let field: CantripSettingsManifest.Field

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingsManifestControl(store: store, field: field)
                .disabled(field.isReadOnly || store.savingKeys.contains(field.key))
            if let help = field.help, field.type != .info {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if field.isReadOnly, let reason = field.readOnlyReason {
                Label(reason, systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let note = store.notes[field.key] {
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error = store.errors[field.key] {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("settings.field.\(field.key)")
    }
}

private struct SettingsManifestControl: View {
    @ObservedObject var store: CantripSettingsStore
    let field: CantripSettingsManifest.Field

    var body: some View {
        switch field.type {
        case .toggle:
            Toggle(field.label, isOn: Binding(
                get: { field.value?.bool ?? false },
                set: { value in Task { await store.set(field, .bool(value)) } }
            ))
        case .choice:
            Picker(field.label, selection: Binding(
                get: { field.value ?? .string("") },
                set: { value in Task { await store.set(field, value) } }
            )) {
                ForEach(field.offeredChoices, id: \.value) { choice in
                    Text(choice.label).tag(choice.value)
                }
            }
        case .integer:
            if let min = field.min, let max = field.max, max - min <= 60 {
                SettingsStepperField(store: store, field: field, range: Int(min)...Int(max))
            } else {
                SettingsTextField(store: store, field: field, numeric: true)
            }
        case .port:
            SettingsTextField(store: store, field: field, numeric: true)
        case .number:
            SettingsSliderField(store: store, field: field)
        case .text, .path:
            SettingsTextField(store: store, field: field, numeric: false)
        case .secret:
            SettingsSecretField(store: store, field: field)
        case .action:
            SettingsActionButton(store: store, field: field)
        case .info:
            VStack(alignment: .leading, spacing: 2) {
                Text(field.label).font(.subheadline)
                Text(field.value?.string ?? "")
                    .font(.caption)
                    .foregroundStyle(field.tone == "error" ? Color.red : field.tone == "warning" ? Color.orange : Color.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        case .unknown:
            LabeledContent(field.label, value: field.display(field.value))
        }
    }
}

/// A whole number stepped up or down; saved once the taps stop.
private struct SettingsStepperField: View {
    @ObservedObject var store: CantripSettingsStore
    let field: CantripSettingsManifest.Field
    let range: ClosedRange<Int>
    @State private var draft: Int?
    @State private var save: Task<Void, Never>?

    var body: some View {
        let value = draft ?? field.value?.int ?? range.lowerBound
        Stepper(value: Binding(get: { value }, set: { schedule($0) }), in: range, step: max(1, Int(field.step ?? 1))) {
            LabeledContent(field.label, value: field.display(.int(value)))
        }
        .onChange(of: field.value) { _, _ in if save == nil { draft = nil } }
    }

    private func schedule(_ value: Int) {
        draft = value
        save?.cancel()
        save = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await store.set(field, .int(value))
            save = nil
            draft = nil
        }
    }
}

/// A decimal on a slider (panel opacity), saved when the drag ends.
private struct SettingsSliderField: View {
    @ObservedObject var store: CantripSettingsStore
    let field: CantripSettingsManifest.Field
    @State private var draft: Double?

    var body: some View {
        let value = draft ?? field.value?.double ?? field.min ?? 0
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(field.label, value: field.display(.double(value)))
            Slider(value: Binding(get: { value }, set: { draft = $0 }),
                   in: (field.min ?? 0)...(field.max ?? 1), step: field.step ?? 0.05) { editing in
                guard !editing, let draft else { return }
                Task {
                    await store.set(field, .double(draft))
                    self.draft = nil
                }
            }
            .accessibilityLabel(field.label)
        }
    }
}

/// Text, a path or a number typed in, saved on Return or when the field loses focus.
private struct SettingsTextField: View {
    @ObservedObject var store: CantripSettingsStore
    let field: CantripSettingsManifest.Field
    let numeric: Bool
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if field.multiline == true {
                Text(field.label)
                TextField("", text: $draft, prompt: Text(field.placeholder ?? field.label), axis: .vertical)
                    .labelsHidden()
                    .lineLimit(3...10)
                    .focused($focused)
            } else if !numeric, field.isReadOnly {
                // A path the Mac only changes there: readable and copyable, not a dimmed field.
                Text(field.label)
                if draft.isEmpty {
                    Text(field.placeholder ?? "Not set").font(.callout).foregroundStyle(.secondary)
                } else {
                    Text(draft)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if !numeric {
                Text(field.label)
                TextField("", text: $draft, prompt: field.placeholder.map { Text($0) })
                    .labelsHidden()
                    .focused($focused)
                    .font(field.type == .path ? .callout.monospaced() : .body)
                    .onSubmit(commit)
                    #if os(iOS)
                    .keyboardType(field.type == .path ? .URL : .default)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(field.label).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    TextField("", text: $draft, prompt: field.placeholder.map { Text($0) })
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 110)
                        .focused($focused)
                        .onSubmit(commit)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        .toolbar {
                            if focused {
                                ToolbarItemGroup(placement: .keyboard) {
                                    Spacer()
                                    Button("Done") { focused = false }
                                }
                            }
                        }
                        #endif
                        .autocorrectionDisabled()
                    if let unit = field.unit { Text(unit).foregroundStyle(.secondary) }
                }
            }
            if field.multiline == true, focused || draft != (field.value?.string ?? "") {
                HStack {
                    Spacer()
                    Button("Revert") { reset() }.disabled(draft == (field.value?.string ?? ""))
                    Button("Save", action: commit).disabled(draft == (field.value?.string ?? ""))
                }
                .buttonStyle(.borderless)
            }
        }
        .onAppear(perform: reset)
        .onChange(of: field.value) { _, _ in if !focused { reset() } }
        .onChange(of: focused) { _, isFocused in if !isFocused, field.multiline != true { commit() } }
    }

    private var shown: String {
        guard let value = field.value else { return "" }
        if numeric { return value.int == 0 && field.zeroLabel != nil ? "" : value.int.map(String.init) ?? "" }
        return value.string ?? ""
    }

    private func reset() { draft = shown }

    private func commit() {
        guard draft != shown else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: CantripSettingValue
        if numeric {
            if text.isEmpty, field.zeroLabel != nil { value = .int(0) }
            else if let number = Int(text) { value = .int(number) }
            else {
                store.errors[field.key] = "\(field.label) is a whole number."
                reset()
                return
            }
        } else {
            value = .string(field.multiline == true ? draft : text)
        }
        Task { await store.set(field, value) }
    }
}

/// A key the Mac keeps: shows only whether one is set; a new one replaces it, Clear removes it.
private struct SettingsSecretField: View {
    @ObservedObject var store: CantripSettingsStore
    let field: CantripSettingsManifest.Field
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(field.label, value: field.isSet == true ? "Set" : "Not set")
            HStack {
                SecureField("", text: $draft, prompt: Text(field.isSet == true ? "Replace…" : "Enter…"))
                    .labelsHidden()
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                Button("Save") {
                    let value = draft
                    draft = ""
                    Task { await store.set(field, .string(value)) }
                }
                .disabled(draft.isEmpty)
                if field.isSet == true {
                    Button("Clear", role: .destructive) { Task { await store.set(field, .string("")) } }
                }
            }
            .buttonStyle(.borderless)
        }
    }
}

private struct SettingsActionButton: View {
    @ObservedObject var store: CantripSettingsStore
    let field: CantripSettingsManifest.Field
    @State private var confirming = false

    var body: some View {
        HStack {
            Button(role: field.destructive == true ? .destructive : nil) {
                if field.confirmation != nil { confirming = true } else { run() }
            } label: {
                Text(field.label)
            }
            if store.savingKeys.contains(field.key) {
                Spacer()
                ProgressView().controlSize(.small)
            }
        }
        .confirmationDialog(field.label, isPresented: $confirming, titleVisibility: .visible) {
            Button(field.label, role: field.destructive == true ? .destructive : nil, action: run)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(field.confirmation ?? "")
        }
    }

    private func run() { Task { await store.run(field) } }
}

/// A change that could cut this device off from the Mac (a port, the pairing token): it stays
/// only if this device, back over its route, keeps it.
struct SettingsPendingSection: View {
    @ObservedObject var store: CantripSettingsStore
    let pending: CantripSettingsManifest.Pending

    var body: some View {
        Section {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = max(0, Int(((store.pendingDeadline ?? context.date).timeIntervalSince(context.date)).rounded(.up)))
                Label(left > 0 ? "Keep \(pending.summary)? The Mac undoes it in \(left) s."
                                : "Undoing \(pending.summary)…",
                      systemImage: "clock.arrow.circlepath")
                    .foregroundStyle(.orange)
            }
            HStack {
                Button("Keep") { Task { await store.keep() } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("settings.pending.keep")
                Button("Undo", role: .destructive) { Task { await store.undo() } }
                    .buttonStyle(.bordered)
            }
        } footer: {
            Text("This change could cut this device off from the Mac, so the Mac undoes it by itself unless you keep it from here.")
        }
        .task(id: pending.id) {
            let wait = max(1, (store.pendingDeadline ?? Date()).timeIntervalSinceNow + 1.5)
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            await store.load(force: true)
        }
    }
}

/// What a button answered with something to keep: a link and its code, or a key shown once.
struct SettingsActionResultSheet: View {
    let shown: CantripSettingsStore.ShownResult
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                if let message = shown.result.message {
                    Section { Text(message).fixedSize(horizontal: false, vertical: true) }
                }
                if let link = shown.result.link, shown.result.qr == true, let code = Self.qrCode(link) {
                    Section {
                        Image(decorative: code, scale: 1)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 260, maxHeight: 260)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .accessibilityLabel("Pairing code")
                    }
                }
                if let text = shown.result.copy ?? shown.result.link {
                    Section {
                        Text(text)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                        Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                            Self.copy(text)
                            copied = true
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(shown.result.title ?? shown.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
        #endif
    }

    static func qrCode(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        return CIContext().createCGImage(image, from: image.extent)
    }

    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
