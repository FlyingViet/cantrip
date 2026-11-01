import CryptoKit
import Foundation

/// An Apple Watch that may talk to Cantrip Home by voice. It signs each request with a key that
/// never leaves the watch (its Secure Enclave); Cantrip keeps only the public key.
struct WatchDevice: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    /// Base64 of the P-256 public key's X9.63 (uncompressed) form.
    var publicKey: String
    var addedAt: Date
    var lastUsedAt: Date?
}

/// The signature a registered device puts on a request (`X-Cantrip-*` headers).
enum DeviceSignature {
    static let version = "cantrip-device-v1"
    static let deviceHeader = "x-cantrip-device"
    static let timeHeader = "x-cantrip-time"
    static let nonceHeader = "x-cantrip-nonce"
    static let signatureHeader = "x-cantrip-signature"
    /// How far a request's clock may be from the Mac's.
    static let allowedSkew: TimeInterval = 300

    static func bodyHash(_ body: Data) -> String {
        SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
    }

    /// What the device signs: the method, the request target as sent, its time and nonce, and
    /// the body's hash, one per line.
    static func canonical(method: String, target: String, time: String, nonce: String, body: Data) -> String {
        [version, method.uppercased(), target, time, nonce, bodyHash(body)].joined(separator: "\n")
    }

    static func publicKey(_ base64: String) -> P256.Signing.PublicKey? {
        Data(base64Encoded: base64).flatMap { try? P256.Signing.PublicKey(x963Representation: $0) }
    }
}

/// The registered watches (`~/.cache/Cantrip/watch-devices.json`, private to the user) and the
/// check of each signed request: a known device, a current time, a nonce not seen before and a
/// valid signature. Thread-safe: requests are checked on the server's queue.
final class WatchDeviceRegistry: @unchecked Sendable {
    static let shared = WatchDeviceRegistry()
    static let maximumDevices = 10

    enum Failure: LocalizedError, Equatable {
        case invalidKey, invalidName, tooMany, unknownDevice, staleTime, replayed, badSignature, missingHeaders

        var errorDescription: String? {
            switch self {
            case .invalidKey: return "publicKey must be a base64 P-256 public key (X9.63)."
            case .invalidName: return "name must be 1 to 60 characters."
            case .tooMany: return "Remove a watch in Cantrip's settings first (up to \(WatchDeviceRegistry.maximumDevices))."
            case .unknownDevice: return "This watch isn't set up with Cantrip anymore."
            case .staleTime: return "The watch's clock is too far from the Mac's."
            case .replayed: return "That request was already used."
            case .badSignature: return "The request's signature doesn't match this watch."
            case .missingHeaders: return "Sign the request with the watch's key."
            }
        }
    }

    let file: URL
    private let lock = NSLock()
    private var devices: [WatchDevice]
    /// Nonces seen per device, with when, for twice the allowed clock skew.
    private var nonces: [UUID: [String: Date]] = [:]
    private var lastUseSaved: [UUID: Date] = [:]
    /// Posted after a watch is added or removed.
    static let changed = Notification.Name("CantripWatchDevicesChanged")

    init(file: URL = CantripPaths.cache("watch-devices.json")) {
        self.file = file
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        devices = (try? Data(contentsOf: file)).flatMap { try? decoder.decode([WatchDevice].self, from: $0) } ?? []
    }

    var all: [WatchDevice] { lock.withLock { devices } }

    /// Adds a watch, or returns the one already registered with this key.
    func register(name: String, publicKey: String, now: Date = Date()) throws -> (device: WatchDevice, created: Bool) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...60).contains(trimmed.count) else { throw Failure.invalidName }
        guard let key = DeviceSignature.publicKey(publicKey) else { throw Failure.invalidKey }
        let normalized = key.x963Representation.base64EncodedString()
        let result: (WatchDevice, Bool) = try lock.withLock {
            if let index = devices.firstIndex(where: { $0.publicKey == normalized }) {
                devices[index].name = trimmed
                return (devices[index], false)
            }
            guard devices.count < Self.maximumDevices else { throw Failure.tooMany }
            let device = WatchDevice(id: UUID(), name: trimmed, publicKey: normalized, addedAt: now, lastUsedAt: nil)
            devices.append(device)
            return (device, true)
        }
        try save()
        NotificationCenter.default.post(name: Self.changed, object: self)
        return result
    }

    @discardableResult
    func remove(_ id: UUID) throws -> Bool {
        let removed = lock.withLock { () -> Bool in
            let before = devices.count
            devices.removeAll { $0.id == id }
            nonces[id] = nil
            return devices.count != before
        }
        if removed {
            try save()
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
        return removed
    }

    /// Whether `headers` (lowercased names) carry a signature at all.
    static func isSigned(_ headers: [String: String]) -> Bool {
        headers[DeviceSignature.deviceHeader] != nil || headers[DeviceSignature.signatureHeader] != nil
    }

    /// The device that signed this request, or why it isn't accepted.
    func verify(method: String, target: String, headers: [String: String], body: Data,
                now: Date = Date()) -> Result<WatchDevice, Failure> {
        guard let rawID = headers[DeviceSignature.deviceHeader], let id = UUID(uuidString: rawID),
              let time = headers[DeviceSignature.timeHeader], let seconds = TimeInterval(time),
              let nonce = headers[DeviceSignature.nonceHeader], (16...128).contains(nonce.count),
              let signatureText = headers[DeviceSignature.signatureHeader],
              let signatureData = Data(base64Encoded: signatureText) else {
            return .failure(.missingHeaders)
        }
        guard let device = lock.withLock({ devices.first { $0.id == id } }),
              let key = DeviceSignature.publicKey(device.publicKey) else {
            return .failure(.unknownDevice)
        }
        guard abs(now.timeIntervalSince1970 - seconds) <= DeviceSignature.allowedSkew else { return .failure(.staleTime) }
        let message = Data(DeviceSignature.canonical(method: method, target: target, time: time, nonce: nonce, body: body).utf8)
        guard let signature = try? P256.Signing.ECDSASignature(derRepresentation: signatureData),
              key.isValidSignature(signature, for: message) else {
            return .failure(.badSignature)
        }
        // Only a correctly signed request uses up its nonce, so nobody can burn a watch's nonces.
        let fresh = lock.withLock { () -> Bool in
            var seen = nonces[id, default: [:]].filter { now.timeIntervalSince($0.value) < 2 * DeviceSignature.allowedSkew }
            guard seen[nonce] == nil else { return false }
            seen[nonce] = now
            nonces[id] = seen
            return true
        }
        guard fresh else { return .failure(.replayed) }
        noteUse(id, now: now)
        return .success(device)
    }

    /// Records when a watch was last used, saving at most once a minute per watch.
    private func noteUse(_ id: UUID, now: Date) {
        let shouldSave = lock.withLock { () -> Bool in
            guard let index = devices.firstIndex(where: { $0.id == id }) else { return false }
            devices[index].lastUsedAt = now
            guard now.timeIntervalSince(lastUseSaved[id] ?? .distantPast) >= 60 else { return false }
            lastUseSaved[id] = now
            return true
        }
        if shouldSave { try? save() }
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try lock.withLock { try encoder.encode(devices) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PrivateFile.write(data, to: file)
    }

    /// A device as clients see it (no key).
    static func json(_ device: WatchDevice) -> [String: Any] {
        [
            "id": device.id.uuidString, "name": device.name,
            "addedAt": ISO8601DateFormatter().string(from: device.addedAt),
            "lastUsedAt": device.lastUsedAt.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
        ]
    }
}
