import Foundation
import CryptoKit

/// `GET/POST /api/v1/usage-fallback`: the Mac-wide backends a run moves through, in order, when
/// the one it's on reports its usage limit, for paired clients. POST `{"backends","revision"}`
/// replaces the chain (`[]` = off); `{"backend","revision"}` from older clients sets its first
/// backend ("" = off); `{"resetLimits":true,"revision"}` lets every backend be tried again now.
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
    /// The fallbacks' BackendKind rawValues in the order they're tried, empty when off.
    let backends: [String]
    /// The first fallback, "" when off, for clients from before the chain.
    let backend: String
    /// The Mac's backend; it's skipped if the chain names it.
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
        let chain = settings.limitFallbackBackends
        let fields = [chain.joined(separator: ","), settings.backend.rawValue]
            + limited.map { "\($0.backend)=\($0.until)" }
        let value = fields.map { "\($0.utf8.count):\($0)" }.joined()
        let revision = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        return .init(backends: chain, backend: chain.first ?? "", primary: settings.backend.rawValue,
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
        } else if keys == ["revision", "backends"], let backends = json["backends"] as? [String] {
            guard backends.allSatisfy({ BackendKind(rawValue: $0) != nil }) else {
                throw UsageFallbackError(status: 400, message: "Choose from the listed backends.")
            }
            guard Set(backends).count == backends.count else {
                throw UsageFallbackError(status: 400, message: "Each backend can be in the chain once.")
            }
            settings.limitFallbackBackends = backends
            Log.write("usage-limit: a paired client set the fallbacks to \(backends.isEmpty ? "off" : backends.joined(separator: " → "))")
        } else if keys == ["revision", "backend"], let backend = json["backend"] as? String {
            guard backend.isEmpty || BackendKind(rawValue: backend) != nil else {
                throw UsageFallbackError(status: 400, message: "Choose Off or one of the listed backends.")
            }
            guard backend != settings.backend.rawValue else {
                throw UsageFallbackError(status: 400, message: "A backend can't fall back on itself. Choose another one.")
            }
            // An older client only sees the first fallback: replace that one, keep the rest.
            let rest = settings.limitFallbackBackends.dropFirst().filter { $0 != backend }
            settings.limitFallbackBackends = backend.isEmpty ? [] : [backend] + rest
            Log.write("usage-limit: a paired client set the first fallback to \(backend.isEmpty ? "off" : backend)")
        } else {
            throw UsageFallbackError(status: 400, message: "Send revision with backends, backend or resetLimits: true.")
        }
        return snapshot(settings: settings, tracker: tracker, now: now)
    }
}
