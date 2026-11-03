#if DEBUG
import CryptoKit
import Foundation

/// Simulator QA without an iPhone: launch with `CANTRIP_WATCH_QA` set to base64 JSON
/// `{"deviceID", "tailnet", "privateKeyRaw" (base64 32-byte P-256 key), "audioFile" (optional)}`.
/// With `audioFile`, that clip is sent instead of a recording; `"autoStart": true` starts a turn at launch;
/// `"talkIntent": true` runs Talk to Cantrip's `perform()` at launch, as the system does for the intent
/// (`"talkIntentAfter": seconds` runs it later, with the app already open).
struct WatchQA {
    let configuration: CantripWatchConfiguration
    let signer: CantripDeviceSigner
    let audioFile: URL?
    let autoStart: Bool
    let talkIntent: Bool
    let talkIntentAfter: Double

    static let current: WatchQA? = parse(ProcessInfo.processInfo.environment["CANTRIP_WATCH_QA"])

    static func parse(_ raw: String?) -> WatchQA? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let data = Data(base64Encoded: padded(raw)),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let deviceID = json["deviceID"] as? String, !deviceID.isEmpty,
              let tailnet = CantripWatchURL.origin(json["tailnet"] as? String),
              let keyText = json["privateKeyRaw"] as? String,
              let keyData = Data(base64Encoded: padded(keyText)),
              let key = try? P256.Signing.PrivateKey(rawRepresentation: keyData)
        else { return nil }
        let audioPath = (json["audioFile"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return WatchQA(
            configuration: CantripWatchConfiguration(
                deviceID: deviceID, tailnet: tailnet,
                internet: CantripWatchURL.origin(json["internet"] as? String),
                serverName: "QA Mac"
            ),
            signer: SoftwareDeviceSigner(key: key),
            audioFile: audioPath.map { URL(fileURLWithPath: $0) },
            autoStart: json["autoStart"] as? Bool ?? false,
            talkIntent: json["talkIntent"] as? Bool ?? false,
            talkIntentAfter: json["talkIntentAfter"] as? Double ?? 0
        )
    }

    private static func padded(_ base64: String) -> String {
        let standard = base64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return standard + String(repeating: "=", count: (4 - standard.count % 4) % 4)
    }
}
#endif
