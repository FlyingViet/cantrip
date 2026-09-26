import AppKit
import ApplicationServices
import CryptoKit
import ScreenCaptureKit

struct DesktopDisplay: Codable, Equatable, Identifiable {
    let id: UInt32
    let name: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    var bounds: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

struct DesktopLease: Codable {
    let id: UUID
    let token: String
    let key: String
    let expiresAt: Double
    let control: Bool
    let displays: [DesktopDisplay]
}

struct DesktopFrame: Codable {
    let id: UUID
    let display: DesktopDisplay
    let width: Int
    let height: Int
    let encryptedJPEG: String

    func associatedData(leaseID: UUID) -> Data {
        Data("cantrip-desktop|\(leaseID)|\(id)|\(display.id)|\(width)|\(height)".utf8)
    }
}

struct DesktopCommand: Codable {
    let frameID: UUID
    let kind: String
    var x: Double?
    var y: Double?
    var text: String?
    var key: String?
    var delta: Int?

    func validate() throws {
        switch kind {
        case "click", "rightClick", "doubleClick":
            guard let x, let y, x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
                throw SessionModelSettingsError(400, "Tap inside the displayed screen.")
            }
        case "text":
            guard let text, !text.isEmpty, text.utf8.count <= 4096, !text.contains("\0") else {
                throw SessionModelSettingsError(400, "Type at most 4096 bytes per input.")
            }
        case "key":
            guard let key, Self.keys[key] != nil else { throw SessionModelSettingsError(400, "Unsupported key.") }
        case "scroll":
            guard let delta, (-10...10).contains(delta), delta != 0 else {
                throw SessionModelSettingsError(400, "Invalid scroll amount.")
            }
        default: throw SessionModelSettingsError(400, "Unsupported desktop action.")
        }
    }

    static let keys: [String: CGKeyCode] = ["return": 36, "tab": 48, "escape": 53, "delete": 51,
                                          "left": 123, "right": 124, "down": 125, "up": 126]
}

@MainActor
final class RemoteDesktop: ObservableObject {
    static let shared = RemoteDesktop()
    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: "remoteDesktopEnabled"); if !enabled { stop() } }
    }
    @Published private(set) var activeUntil: Double?
    private let defaults: UserDefaults
    private let permission: () -> (screen: Bool, control: Bool)
    private let listDisplays: () throws -> [DesktopDisplay]
    private let capture: (DesktopDisplay) async throws -> (Data, Int, Int)
    private let post: (DesktopCommand, DesktopDisplay) throws -> Void
    private let now: () -> Date
    private var lease: DesktopLease?
    private var lastRead = Date.distantPast
    private var sequence = 0
    private var lastInteraction: UInt32?
    private var frames: [UUID: (DesktopDisplay, Date)] = [:]
    private var captureInFlight = false
    private var timer: Timer?

    init(defaults: UserDefaults = .standard,
         permission: @escaping () -> (screen: Bool, control: Bool) = { (CGPreflightScreenCaptureAccess(), AXIsProcessTrusted()) },
         listDisplays: @escaping () throws -> [DesktopDisplay] = RemoteDesktop.displays,
         capture: @escaping (DesktopDisplay) async throws -> (Data, Int, Int) = RemoteDesktop.capture,
         post: @escaping (DesktopCommand, DesktopDisplay) throws -> Void = RemoteDesktop.post,
         now: @escaping () -> Date = Date.init) {
        self.defaults = defaults; self.permission = permission; self.listDisplays = listDisplays
        self.capture = capture; self.post = post; self.now = now
        enabled = defaults.bool(forKey: "remoteDesktopEnabled")
    }

    func snapshot() -> MacAccessSnapshot {
        expire()
        return MacAccessSnapshot(name: Host.current().localizedName ?? "Cantrip Mac", desktopEnabled: enabled,
                                 permissions: MacAttention.shared.permissions(), issues: MacAttention.shared.issues,
                                 activeUntil: activeUntil)
    }

    func start(control: Bool) throws -> DesktopLease {
        expire()
        guard enabled else { throw SessionModelSettingsError(403, "Enable View Mac in Cantrip's settings on the Mac first.") }
        guard lease == nil else { throw SessionModelSettingsError(409, "Another View Mac session is active. End it on the Mac or wait for it to expire.") }
        let access = permission()
        guard access.screen else {
            MacAttention.shared.record(.screenRecording)
            throw SessionModelSettingsError(409, "Screen Recording permission is needed on the Mac. Viewing cannot grant its own permission.")
        }
        guard !control || access.control else {
            MacAttention.shared.record(.accessibility)
            throw SessionModelSettingsError(409, "Accessibility permission is needed on the Mac for remote control. View-only mode is still available.")
        }
        let displays = try listDisplays()
        guard !displays.isEmpty else { throw SessionModelSettingsError(503, "No accessible Mac display. Log in at the Mac.") }
        let value = DesktopLease(id: UUID(), token: Self.randomKey(), key: Self.randomKey(),
                                 expiresAt: now().addingTimeInterval(300).timeIntervalSince1970,
                                 control: control, displays: displays)
        lease = value; activeUntil = value.expiresAt; lastRead = now(); sequence = 0; lastInteraction = nil; frames = [:]
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.expire() }
        }
        return value
    }

    func stop() {
        lease = nil; activeUntil = nil; lastInteraction = nil; frames.removeAll(); timer?.invalidate(); timer = nil
    }

    func stop(id: UUID, token: String) throws {
        _ = try authorize(id: id, token: token)
        stop()
    }

    private func expire() {
        if let lease, now().timeIntervalSince1970 >= lease.expiresAt || now().timeIntervalSince(lastRead) > 60 { stop() }
    }

    private func authorize(id: UUID, token: String) throws -> DesktopLease {
        expire()
        guard enabled, let lease, lease.id == id, Self.equal(token, lease.token) else {
            throw SessionModelSettingsError(409, "View Mac ended or expired. Start a new session.")
        }
        return lease
    }

    func frame(id: UUID, token: String, displayID: UInt32) async throws -> DesktopFrame {
        let lease = try authorize(id: id, token: token)
        guard permission().screen else {
            stop(); MacAttention.shared.record(.screenRecording)
            throw SessionModelSettingsError(409, "Screen Recording permission was removed.")
        }
        guard !captureInFlight else { throw SessionModelSettingsError(409, "A screen refresh is already in progress.") }
        let displays = try listDisplays()
        guard let display = displays.first(where: { $0.id == displayID }),
              lease.displays.contains(display) else {
            stop()
            throw SessionModelSettingsError(409, "Mac display layout changed. Start a new viewing session.")
        }
        captureInFlight = true
        defer { captureInFlight = false }
        let (jpeg, width, height) = try await capture(display)
        _ = try authorize(id: id, token: token)
        guard permission().screen, try listDisplays().contains(display) else {
            stop()
            throw SessionModelSettingsError(409, "The display or its permission changed during capture.")
        }
        let frame = DesktopFrame(id: UUID(), display: display, width: width, height: height, encryptedJPEG: "")
        let sealed = try AES.GCM.seal(jpeg, using: SymmetricKey(data: Data(base64Encoded: lease.key)!),
                                      authenticating: frame.associatedData(leaseID: id))
        guard let data = sealed.combined else { throw SessionModelSettingsError(500, "Could not encrypt the screen frame.") }
        frames = frames.filter { now().timeIntervalSince($0.value.1) < 15 }
        frames[frame.id] = (display, now())
        lastRead = now()
        return DesktopFrame(id: frame.id, display: display, width: width, height: height, encryptedJPEG: data.base64EncodedString())
    }

    func input(id: UUID, token: String, sequence incoming: Int, encrypted: String) throws {
        let lease = try authorize(id: id, token: token)
        guard lease.control, permission().control, permission().screen else {
            if lease.control { stop() }
            throw SessionModelSettingsError(403, "Remote control is unavailable or permission was removed. No input was sent.")
        }
        guard incoming > sequence, incoming <= 9_007_199_254_740_991,
              encrypted.utf8.count < 20000, let data = Data(base64Encoded: encrypted) else {
            throw SessionModelSettingsError(409, "Repeated or invalid desktop input. It was not replayed.")
        }
        let plain: Data
        do {
            plain = try AES.GCM.open(AES.GCM.SealedBox(combined: data),
                using: SymmetricKey(data: Data(base64Encoded: lease.key)!),
                authenticating: Data("cantrip-desktop|\(id)|input|\(incoming)".utf8))
        } catch { throw SessionModelSettingsError(400, "Desktop input could not be authenticated.") }
        let command: DesktopCommand
        do { command = try JSONDecoder().decode(DesktopCommand.self, from: plain) }
        catch { throw SessionModelSettingsError(400, "Invalid desktop input.") }
        try command.validate()
        guard let (display, date) = frames[command.frameID], now().timeIntervalSince(date) < 15,
              try listDisplays().contains(display) else {
            throw SessionModelSettingsError(409, "Refresh the screen before sending input. The previous frame is stale.")
        }
        if command.kind == "text" || command.kind == "key" || command.kind == "scroll" {
            // Keyboard and scroll act on the Mac's current focus; the client must visibly select it.
            guard let lastInteraction, lastInteraction == display.id else {
                throw SessionModelSettingsError(409, "Click the target field or window in this display before typing or scrolling.")
            }
        }
        // Claim before posting: a lost acknowledgement must never type or click twice.
        sequence = incoming
        try post(command, display)
        if ["click", "rightClick", "doubleClick"].contains(command.kind) { lastInteraction = display.id }
        lastRead = now()
    }

    private static func equal(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func randomKey() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
    }

    nonisolated static func displays() throws -> [DesktopDisplay] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16), count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else {
            throw SessionModelSettingsError(503, "Could not enumerate Mac displays.")
        }
        return ids.prefix(Int(count)).enumerated().map { index, id in
            let bounds = CGDisplayBounds(id)
            return DesktopDisplay(id: id, name: CGDisplayIsMain(id) != 0 ? "Main display" : "Display \(index + 1)",
                                  x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height)
        }
    }

    nonisolated static func capture(_ display: DesktopDisplay) async throws -> (Data, Int, Int) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let screen = content.displays.first(where: { $0.displayID == display.id }) else {
            throw SessionModelSettingsError(503, "This screen cannot be captured. Local interaction may be required.")
        }
        let configuration = SCStreamConfiguration()
        let scale = min(1, 1600 / Double(max(screen.width, 1)))
        configuration.width = max(1, Int(Double(screen.width) * scale))
        configuration.height = max(1, Int(Double(screen.height) * scale))
        configuration.showsCursor = true
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: screen, excludingWindows: []), configuration: configuration)
        guard let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.65]) else {
            throw SessionModelSettingsError(503, "Could not encode the screen frame.")
        }
        return (jpeg, image.width, image.height)
    }

    nonisolated static func post(_ command: DesktopCommand, display: DesktopDisplay) throws {
        try command.validate()
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw SessionModelSettingsError(503, "Mac input events are unavailable.")
        }
        func key(_ code: CGKeyCode, text: String? = nil) throws {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else {
                throw SessionModelSettingsError(503, "Could not create keyboard input.")
            }
            if let text {
                let units = Array(text.utf16)
                down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            }
            down.flags = []; up.flags = []
            down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        }
        switch command.kind {
        case "click", "rightClick", "doubleClick":
            let point = Self.point(x: command.x!, y: command.y!, display: display)
            let right = command.kind == "rightClick"
            for click in 1...(command.kind == "doubleClick" ? 2 : 1) {
                guard let down = CGEvent(mouseEventSource: source, mouseType: right ? .rightMouseDown : .leftMouseDown,
                                        mouseCursorPosition: point, mouseButton: right ? .right : .left),
                      let up = CGEvent(mouseEventSource: source, mouseType: right ? .rightMouseUp : .leftMouseUp,
                                      mouseCursorPosition: point, mouseButton: right ? .right : .left) else {
                    throw SessionModelSettingsError(503, "Could not create pointer input.")
                }
                down.setIntegerValueField(.mouseEventClickState, value: Int64(click))
                up.setIntegerValueField(.mouseEventClickState, value: Int64(click))
                down.flags = []; up.flags = []
                down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
            }
        case "text":
            for character in command.text! { try key(0, text: String(character)) }
        case "key": try key(DesktopCommand.keys[command.key!]!)
        case "scroll":
            guard let event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 1,
                                      wheel1: Int32(command.delta!), wheel2: 0, wheel3: 0) else {
                throw SessionModelSettingsError(503, "Could not create scroll input.")
            }
            event.post(tap: .cghidEventTap)
        default: throw SessionModelSettingsError(400, "Unsupported desktop action.")
        }
    }

    nonisolated static func point(x: Double, y: Double, display: DesktopDisplay) -> CGPoint {
        CGPoint(x: display.x + min(max(x, 0), 0.999999) * display.width,
                y: display.y + min(max(y, 0), 0.999999) * display.height)
    }
}
