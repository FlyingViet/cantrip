import CryptoKit
import Foundation

/// Device signatures for watch requests to the Mac (`cantrip-device-v1`).
enum CantripDeviceSignature {
    static let version = "cantrip-device-v1"
    static let deviceHeader = "X-Cantrip-Device"
    static let timeHeader = "X-Cantrip-Time"
    static let nonceHeader = "X-Cantrip-Nonce"
    static let signatureHeader = "X-Cantrip-Signature"

    /// Lowercase hex SHA-256 of the raw body bytes.
    static func bodyDigest(_ body: Data) -> String {
        SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
    }

    /// The six signed lines joined by "\n", without a trailing newline.
    static func canonicalString(method: String, target: String, time: String, nonce: String, body: Data) -> String {
        [version, method.uppercased(), target, time, nonce, bodyDigest(body)].joined(separator: "\n")
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func makeNonce() -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<18).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    /// The four signature headers. `sign` returns the DER signature of the message it is given.
    static func headers(
        deviceID: String, method: String, target: String, body: Data,
        date: Date = Date(), nonce: String = makeNonce(),
        sign: (Data) throws -> Data
    ) rethrows -> [String: String] {
        let time = String(Int(date.timeIntervalSince1970.rounded(.down)))
        let message = canonicalString(method: method, target: target, time: time, nonce: nonce, body: body)
        let signature = try sign(Data(message.utf8))
        return [
            deviceHeader: deviceID,
            timeHeader: time,
            nonceHeader: nonce,
            signatureHeader: signature.base64EncodedString(),
        ]
    }
}

/// One voice turn as the Mac reports it.
struct CantripVoiceTurn: Decodable, Equatable {
    enum Status: String, Equatable {
        case queued, thinking, done, failed
    }

    let id: String
    let status: Status
    let transcript: String?
    let reply: String?
    let spoken: String?
    let error: String?
    let createdAt: String?

    var isFinished: Bool { status == .done || status == .failed }

    private enum CodingKeys: String, CodingKey {
        case id, status, transcript, reply, spoken, error, createdAt
    }

    init(id: String, status: Status, transcript: String? = nil, reply: String? = nil,
         spoken: String? = nil, error: String? = nil, createdAt: String? = nil) {
        self.id = id
        self.status = status
        self.transcript = transcript
        self.reply = reply
        self.spoken = spoken
        self.error = error
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        // An unknown status counts as still working, so polling continues.
        status = (try? container.decode(String.self, forKey: .status)).flatMap(Status.init(rawValue:)) ?? .thinking
        transcript = try? container.decodeIfPresent(String.self, forKey: .transcript)
        reply = try? container.decodeIfPresent(String.self, forKey: .reply)
        spoken = try? container.decodeIfPresent(String.self, forKey: .spoken)
        error = try? container.decodeIfPresent(String.self, forKey: .error)
        createdAt = try? container.decodeIfPresent(String.self, forKey: .createdAt)
    }

    /// What to say aloud: `spoken`, else the reply without markdown.
    var speakableText: String {
        let spoken = (spoken ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return spoken.isEmpty ? CantripWatchText.plain(reply ?? "") : spoken
    }
}

struct CantripVoiceTurnEnvelope: Decodable {
    let turn: CantripVoiceTurn
}

struct CantripVoiceConfig: Decodable, Equatable {
    struct Home: Decodable, Equatable {
        let available: Bool
    }

    let home: Home?
    let internet: String?
}

struct CantripServerErrorBody: Decodable {
    let error: String
}

/// Errors the watch shows, in plain words.
enum CantripWatchError: LocalizedError, Equatable {
    case notSetUp
    case unreachable
    case unauthorized
    case noSpeech
    case homeOff
    case microphoneDenied
    case recordingFailed
    case clipTooLarge
    case stillWorking
    case timedOut
    case server(Int, String?)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notSetUp:
            return "Open Cantrip on your watch and set it up with your iPhone first."
        case .unreachable:
            return "Can't reach your Mac. Keep your iPhone nearby, or turn on the internet route in Cantrip on the Mac."
        case .unauthorized:
            return "This watch isn't set up anymore. Set it up again with your iPhone."
        case .noSpeech:
            return "Didn't catch that. Try again."
        case .homeOff:
            return "Cantrip Home is off on your Mac. Turn it on in Cantrip, then try again."
        case .microphoneDenied:
            return "Cantrip can't use the microphone. Allow it in Settings on your watch."
        case .recordingFailed:
            return "The microphone didn't start. Try again."
        case .clipTooLarge:
            return "That was too long to send. Try a shorter request."
        case .stillWorking:
            return "Cantrip Home is still working on it. Open Cantrip on your watch to hear the answer."
        case .timedOut:
            return "Cantrip Home took too long to answer. Check Cantrip on your Mac."
        case .server(let status, let message):
            if let message, !message.isEmpty { return message }
            return "Your Mac couldn't take that request (error \(status)). Try again."
        case .failed(let message):
            return message
        }
    }

    /// The error for an HTTP status the Mac answered with.
    static func http(_ status: Int, body: Data) -> CantripWatchError {
        switch status {
        case 401: return .unauthorized
        case 422: return .noSpeech
        case 503: return .homeOff
        default:
            let message = (try? JSONDecoder().decode(CantripServerErrorBody.self, from: body))?.error
            return .server(status, message)
        }
    }
}

/// The routes to the Mac, in the order to try them.
enum CantripWatchRoute: String, CaseIterable, Equatable {
    case tailnet
    case internet

    /// Tailnet, then internet; the route that last worked goes first.
    static func order(tailnet: URL?, internet: URL?, lastWorking: CantripWatchRoute?) -> [(CantripWatchRoute, URL)] {
        var routes: [(CantripWatchRoute, URL)] = []
        if let tailnet { routes.append((.tailnet, tailnet)) }
        if let internet { routes.append((.internet, internet)) }
        if let lastWorking, let index = routes.firstIndex(where: { $0.0 == lastWorking }), index > 0 {
            routes.insert(routes.remove(at: index), at: 0)
        }
        return routes
    }
}

enum CantripWatchURL {
    /// An HTTPS origin (loopback HTTP only in DEBUG builds), without a path.
    static func origin(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              var components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil
        else { return nil }
        #if DEBUG
        let loopback = host == "127.0.0.1" || host == "localhost"
        guard scheme == "https" || (scheme == "http" && loopback) else { return nil }
        #else
        guard scheme == "https" else { return nil }
        #endif
        components.scheme = scheme
        components.host = host
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// `base` + a request target (path and optional query), sent exactly as signed.
    static func url(base: URL, target: String) -> URL? {
        guard target.hasPrefix("/"),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false),
              let parsed = URLComponents(string: target), parsed.host == nil
        else { return nil }
        components.percentEncodedPath = parsed.percentEncodedPath
        components.percentEncodedQuery = parsed.percentEncodedQuery
        components.fragment = nil
        guard let url = components.url, url.host == base.host else { return nil }
        return url
    }

    static func turnTarget(id: String, wait: Int) -> String? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-")
        guard !id.isEmpty, id.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return "/api/v1/voice/turns/\(id)?wait=\(min(max(wait, 0), 25))"
    }
}

/// Decides when a recording should stop, from the microphone's average power (dBFS).
struct CantripSilenceDetector {
    enum Decision: Equatable {
        case keepRecording
        case speechEnded
        case maxDuration
        case noSpeech
    }

    var silenceAfterSpeech: TimeInterval = 1.5
    var maxDuration: TimeInterval = 60
    var noSpeechTimeout: TimeInterval = 10
    /// Speech is at least `minimumSpeechLevel` and `speechMargin` above the quietest level heard
    /// before it, but never needs to be louder than `loudSpeechLevel`.
    var minimumSpeechLevel: Float = -40
    var loudSpeechLevel: Float = -25
    var speechMargin: Float = 12

    private(set) var speechStarted = false
    private var noiseFloor: Float?
    private var loudSince: TimeInterval?
    private var lastSpeech: TimeInterval = 0

    var speechLevel: Float {
        max(minimumSpeechLevel, min(loudSpeechLevel, (noiseFloor ?? -160) + speechMargin))
    }

    mutating func add(level: Float, at time: TimeInterval) -> Decision {
        if time >= maxDuration { return .maxDuration }
        if !speechStarted {
            noiseFloor = min(noiseFloor ?? level, level)
        }
        if level >= speechLevel {
            if speechStarted {
                lastSpeech = time
            } else if let since = loudSince {
                if time - since >= 0.2 {
                    speechStarted = true
                    lastSpeech = time
                }
            } else {
                loudSince = time
            }
        } else if !speechStarted {
            loudSince = nil
        }
        if speechStarted, time - lastSpeech >= silenceAfterSpeech { return .speechEnded }
        if !speechStarted, time >= noSpeechTimeout { return .noSpeech }
        return .keepRecording
    }
}

enum CantripWatchText {
    /// Markdown reduced to readable plain text for the small screen.
    static func plain(_ markdown: String) -> String {
        var lines: [String] = []
        for rawLine in markdown.components(separatedBy: "\n") {
            var line = rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { continue }
            if trimmed.hasPrefix("#") {
                line = String(trimmed.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("> ") {
                line = String(trimmed.dropFirst(2))
            } else if trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") || trimmed.hasPrefix("- ") {
                line = "• " + trimmed.dropFirst(2)
            }
            line = line.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            for marker in ["**", "__", "~~", "`"] {
                line = line.replacingOccurrences(of: marker, with: "")
            }
            line = line.replacingOccurrences(of: #"(?<![\w*])\*(?!\s)([^*\n]+?)(?<!\s)\*(?![\w*])"#, with: "$1",
                                             options: .regularExpression)
            lines.append(line)
        }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
