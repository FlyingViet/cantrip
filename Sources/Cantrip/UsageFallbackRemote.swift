import Foundation
import CryptoKit

/// `GET/POST /api/v1/usage-fallback`: the Mac-wide backend a run moves to when the chosen one
/// reports its usage limit, for paired clients. POST `{"backend","revision"}` sets it ("" = off);
/// `{"resetLimits":true,"revision"}` lets every backend be tried again now.
struct UsageFallbackSnapshot: Encodable, Equatable {
    struct Choice: Encodable, Equatable {
        let id: String
        let label: String
    }
    struct Limited: Encodable, Equatable {
        let backend: String
        let until: String
        let untilLabel: String
    }
    /// The fallback's BackendKind rawValue, "" when off.
    let backend: String
    /// The Mac's backend; it can't be its own fallback.
    let primary: String
    let choices: [Choice]
    let limited: [Limited]
    let revision: String
}

struct UsageFallbackError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

@MainActor
enum UsageFallbackRemote {
    static func snapshot(settings: AppSettings = .shared, tracker: BackendLimitTracker = .shared,
                         now: Date = Date()) -> UsageFallbackSnapshot {
        let limited = BackendKind.allCases.compactMap { kind -> UsageFallbackSnapshot.Limited? in
            tracker.limitedUntil(kind, now: now).map {
                .init(backend: kind.rawValue, until: ISODate.string(from: $0),
                      untilLabel: BackendFallback.untilLabel($0, now: now))
            }
        }
        let choices = BackendKind.allCases.filter { $0 != settings.backend }
            .map { UsageFallbackSnapshot.Choice(id: $0.rawValue, label: settings.backendLabel($0)) }
        let fields = [settings.limitFallbackBackend, settings.backend.rawValue]
            + limited.map { "\($0.backend)=\($0.until)" }
        let value = fields.map { "\($0.utf8.count):\($0)" }.joined()
        let revision = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        return .init(backend: settings.limitFallbackBackend, primary: settings.backend.rawValue,
                     choices: choices, limited: limited, revision: revision)
    }

    static func apply(_ json: [String: Any], settings: AppSettings = .shared,
                      tracker: BackendLimitTracker = .shared, now: Date = Date()) throws -> UsageFallbackSnapshot {
        guard let revision = json["revision"] as? String else {
            throw UsageFallbackError(status: 400, message: "Provide the revision you loaded.")
        }
        guard revision == snapshot(settings: settings, tracker: tracker, now: now).revision else {
            throw UsageFallbackError(status: 409, message: "The fallback changed on another device. Reload before saving.")
        }
        let keys = Set(json.keys)
        if keys == ["revision", "resetLimits"], json["resetLimits"] as? Bool == true {
            tracker.clear()
            Log.write("usage-limit: a paired client cleared every backend's limit")
        } else if keys == ["revision", "backend"], let backend = json["backend"] as? String {
            guard backend.isEmpty || BackendKind(rawValue: backend) != nil else {
                throw UsageFallbackError(status: 400, message: "Choose Off or one of the listed backends.")
            }
            guard backend != settings.backend.rawValue else {
                throw UsageFallbackError(status: 400, message: "A backend can't fall back on itself. Choose another one.")
            }
            settings.limitFallbackBackend = backend
            Log.write("usage-limit: a paired client set the fallback to \(backend.isEmpty ? "off" : backend)")
        } else {
            throw UsageFallbackError(status: 400, message: "Send revision with either backend or resetLimits: true.")
        }
        return snapshot(settings: settings, tracker: tracker, now: now)
    }
}
