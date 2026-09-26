import CryptoKit
import SwiftUI

struct CantripMacPermission: Decodable, Identifiable {
    let permission: String
    let title: String
    let state: String
    var id: String { permission }
}

struct CantripMacIssue: Decodable, Identifiable {
    let id: UUID
    let permission: String
    let title: String
}

struct CantripMacAccess: Decodable {
    let name: String
    let desktopEnabled: Bool
    let permissions: [CantripMacPermission]
    let issues: [CantripMacIssue]
    let activeUntil: Double?
}

struct CantripDesktopDisplay: Codable, Equatable, Identifiable {
    let id: UInt32
    let name: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct CantripDesktopLease: Decodable {
    let id: UUID
    let token: String
    let key: String
    let expiresAt: Double
    let control: Bool
    let displays: [CantripDesktopDisplay]
}

struct CantripDesktopFrame: Decodable {
    let id: UUID
    let display: CantripDesktopDisplay
    let width: Int
    let height: Int
    let encryptedJPEG: String

    func decrypt(lease: CantripDesktopLease) throws -> Data {
        guard let key = Data(base64Encoded: lease.key), key.count == 32,
              let encrypted = Data(base64Encoded: encryptedJPEG), encrypted.count <= 8 * 1024 * 1024,
              (1...8192).contains(width), (1...8192).contains(height) else {
            throw CantripRemoteError.invalidResponse
        }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: SymmetricKey(data: key),
            authenticating: Data("cantrip-desktop|\(lease.id)|\(id)|\(display.id)|\(width)|\(height)".utf8))
    }
}

struct CantripDesktopCommand: Encodable {
    let frameID: UUID
    let kind: String
    var x: Double?
    var y: Double?
    var text: String?
    var key: String?
    var delta: Int?

    func encrypted(lease: CantripDesktopLease, sequence: Int) throws -> String {
        guard let data = Data(base64Encoded: lease.key), data.count == 32 else { throw CantripRemoteError.invalidResponse }
        let sealed = try AES.GCM.seal(JSONEncoder().encode(self), using: SymmetricKey(data: data),
            authenticating: Data("cantrip-desktop|\(lease.id)|input|\(sequence)".utf8))
        guard let value = sealed.combined else { throw CantripRemoteError.invalidResponse }
        return value.base64EncodedString()
    }
}

@MainActor
final class CantripDesktopModel: ObservableObject {
    @Published private(set) var lease: CantripDesktopLease?
    @Published private(set) var frame: CantripDesktopFrame?
    @Published private(set) var image: UIImage?
    @Published var displayID: UInt32? {
        didSet { if displayID != oldValue { frame = nil; image = nil } }
    }
    @Published private(set) var busy = false
    @Published var error: String?
    private let remote: CantripRemoteModel
    let identity: UUID
    private var sequence = 0
    private var poll: Task<Void, Never>?
    private var starting: Task<CantripDesktopLease, Error>?
    private var generation = 0

    init(remote: CantripRemoteModel) { self.remote = remote; identity = remote.usageIdentity }

    func start(control: Bool) async {
        guard !busy, lease == nil else { return }
        busy = true
        defer { busy = false }
        let generation = generation
        do {
            let task = Task { try await remote.startDesktop(control: control, identity: identity) }
            starting = task
            let value = try await task.value
            starting = nil
            guard self.generation == generation, remote.usageIdentity == identity else { throw CancellationError() }
            lease = value; displayID = value.displays.first?.id; sequence = 0; error = nil
            poll = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, let lease = self.lease, let display = self.displayID else { return }
                    do {
                        let frame = try await self.remote.desktopFrame(lease: lease, displayID: display, identity: self.identity)
                        guard self.lease?.id == lease.id, !Task.isCancelled, self.remote.usageIdentity == self.identity else { return }
                        guard self.displayID == display else { continue }
                        let data = try frame.decrypt(lease: lease)
                        guard let image = UIImage(data: data) else { throw CantripRemoteError.invalidResponse }
                        self.frame = frame; self.image = image
                        try await Task.sleep(for: .seconds(1))
                    } catch is CancellationError { return }
                    catch {
                        self.error = error.localizedDescription + " Viewing stopped; start a new session to reconnect."
                        await self.stop()
                        return
                    }
                }
            }
        } catch is CancellationError { error = "Authentication or connection changed. No viewing session was confirmed." }
        catch { self.error = error.localizedDescription }
    }

    func stop() async {
        generation += 1
        starting?.cancel(); starting = nil
        poll?.cancel(); poll = nil
        let old = lease
        lease = nil; frame = nil; image = nil
        if let old {
            do { try await remote.stopDesktop(lease: old, identity: identity) }
            catch { self.error = "View cleared. The Mac may keep the lease until its 60-second idle timeout: \(error.localizedDescription)" }
        }
    }

    func send(_ command: CantripDesktopCommand) async {
        guard let lease, lease.control, !busy else { return }
        busy = true
        defer { busy = false }
        sequence += 1
        do {
            let encrypted = try command.encrypted(lease: lease, sequence: sequence)
            try await remote.desktopInput(lease: lease, sequence: sequence, encrypted: encrypted, identity: identity)
            error = nil
        } catch { self.error = error.localizedDescription + " Input was not retried. Check the screen before trying again." }
    }
}

struct CantripMacAccessView: View {
    @ObservedObject var remote: CantripRemoteModel
    @StateObject private var desktop: CantripDesktopModel
    @State private var snapshot: CantripMacAccess?
    @State private var error: String?
    @AppStorage("cantrip.desktop.control") private var control = false
    @State private var zoom = 1
    @State private var clickKind = "click"
    @State private var text = ""
    @State private var settingsBusy = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    init(remote: CantripRemoteModel) {
        self.remote = remote
        _desktop = StateObject(wrappedValue: CantripDesktopModel(remote: remote))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(snapshot?.name ?? "Cantrip Mac").font(.headline)
                Text("Explicit remote viewing only. Screen frames and typed input are not saved or sent to the model. The paired connection carries the viewing key; only use a trusted HTTPS endpoint.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let error = desktop.error ?? error { Text(error).foregroundStyle(.orange) }
                if let lease = desktop.lease {
                    Label("View Mac active - expires in five minutes", systemImage: "display")
                    Picker("Display", selection: $desktop.displayID) {
                        ForEach(lease.displays) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Picker("Zoom", selection: $zoom) {
                        Text("1x").tag(1); Text("2x").tag(2); Text("3x").tag(3)
                    }.pickerStyle(.segmented)
                    screen
                    if lease.control { controls }
                    Text("Protected dialogs may be hidden or reject input. A sent click is not confirmation that macOS authorized an operation. Touch ID cannot be performed remotely.")
                        .font(.footnote)
                    Button("End View Mac", role: .destructive) { text = ""; Task { await desktop.stop(); await load() } }
                        .buttonStyle(.bordered).frame(minHeight: 44)
                } else {
                    Toggle("Enable keyboard and pointer control", isOn: $control)
                        .disabled(desktop.busy)
                        .accessibilityIdentifier("cantrip.desktop.control")
                    Text("Your control preference is saved. Authenticate to start each session; Done ends the session.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button {
                        Task { await desktop.start(control: control) }
                    } label: {
                        Label(control ? "Authenticate & Control Mac" : "Authenticate & View Mac", systemImage: "faceid")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(snapshot?.desktopEnabled != true || desktop.busy)
                    if snapshot?.desktopEnabled != true {
                        Text("First enable “Allow paired clients to view and control this Mac” in Cantrip settings on the Mac. The phone cannot enable this permission remotely.")
                    }
                }
                permissions
            }.padding()
        }
        .navigationTitle("Mac Access").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .primaryAction) { Button("Refresh") { Task { await load() } } }
        }
        .task { await load() }
        .onDisappear { text = ""; Task { await desktop.stop() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || (phase == .inactive && desktop.lease != nil) {
                text = ""; Task { await desktop.stop() }
            }
        }
        .onChange(of: remote.usageIdentity) { _, _ in text = ""; Task { await desktop.stop() }; dismiss() }
        .onChange(of: desktop.displayID) { _, _ in text = "" }
    }

    @ViewBuilder private var screen: some View {
        if let image = desktop.image, let frame = desktop.frame {
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    let width = geometry.size.width * CGFloat(zoom)
                    let height = width * CGFloat(frame.height) / CGFloat(frame.width)
                    Image(uiImage: image).resizable().frame(width: width, height: height)
                        .contentShape(Rectangle())
                        .gesture(SpatialTapGesture().onEnded { event in
                            guard desktop.lease?.control == true else { return }
                            let command = CantripDesktopCommand(frameID: frame.id, kind: clickKind,
                                x: Double(event.location.x / width), y: Double(event.location.y / height))
                            Task { await desktop.send(command) }
                        })
                        .accessibilityLabel("Live Mac screen. Use zoom and tap to control when enabled.")
                        .accessibilityAction(named: "Click center of display") {
                            Task { await desktop.send(.init(frameID: frame.id, kind: "click", x: 0.5, y: 0.5)) }
                        }
                }
            }
            .frame(height: 380)
            .disabled(desktop.busy)
        } else { ProgressView("Waiting for a screen frame...") }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Tap action", selection: $clickKind) {
                Text("Click").tag("click"); Text("Right click").tag("rightClick"); Text("Double click").tag("doubleClick")
            }
            SecureField("Type into the focused Mac field", text: $text)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Text("Click the target field first. Confirm its focus before sending a password; the Mac may display typed text.")
                .font(.footnote).foregroundStyle(.secondary)
            Button("Send Text") {
                guard let frame = desktop.frame else { return }
                let value = text; text = ""
                Task { await desktop.send(.init(frameID: frame.id, kind: "text", text: value)) }
            }.disabled(text.isEmpty)
            ScrollView(.horizontal) {
                HStack {
                    ForEach(["return", "tab", "escape", "delete", "left", "right", "up", "down"], id: \.self) { key in
                        Button(key.capitalized) {
                            guard let frame = desktop.frame else { return }
                            Task { await desktop.send(.init(frameID: frame.id, kind: "key", key: key)) }
                        }.buttonStyle(.bordered).frame(minHeight: 44)
                    }
                }
            }
            HStack {
                Button("Scroll up") { scroll(3) }
                Button("Scroll down") { scroll(-3) }
            }
        }.disabled(desktop.busy || desktop.frame == nil)
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mac Permissions & Attention").font(.headline)
            ForEach(snapshot?.issues ?? []) { Text($0.title).foregroundStyle(.orange) }
            ForEach(snapshot?.permissions ?? []) { permission in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(permission.title): \(stateLabel(permission.state))")
                    Button("Open \(permission.title) on Mac") {
                        settingsBusy = true
                        Task {
                            do { try await remote.openMacSettings(permission.permission, identity: desktop.identity); error = nil }
                            catch { self.error = error.localizedDescription }
                            settingsBusy = false
                        }
                    }.frame(minHeight: 44)
                }
            }
            Text("Full Disk Access needs a manual check. Keychain status covers Cantrip's own credential reads, not every application's dialog. These buttons open settings; they never grant permissions.")
                .font(.footnote).foregroundStyle(.secondary)
        }.disabled(settingsBusy)
    }

    private func stateLabel(_ state: String) -> String {
        switch state {
        case "granted": return "Granted"
        case "notGranted": return "Not granted"
        case "needsAttention": return "Needs attention"
        case "checkedWhenUsed": return "Checked when Cantrip reads credentials"
        case "localBiometricsAvailable": return "Available on the Mac only"
        case "localPasswordRequired": return "Authenticate on the Mac"
        default: return "Check on Mac"
        }
    }

    private func scroll(_ delta: Int) {
        guard let frame = desktop.frame else { return }
        Task { await desktop.send(.init(frameID: frame.id, kind: "scroll", delta: delta)) }
    }

    private func load() async {
        do { snapshot = try await remote.macAccess(); error = nil }
        catch { self.error = error.localizedDescription }
    }
}
