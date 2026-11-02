import CoreLocation
import Foundation

/// Where a paired client is, sent with one message while its "Share location" setting is on.
/// Coarse (about 1 km) unless the client chose precise. Kept in memory only and attached to
/// that message's backend prompt: never shown in the chat, journaled, logged or written to memory.
struct RemoteClientLocation: Equatable {
    /// A fix older than this isn't used; the reply falls back to the Mac's location.
    static let maximumAge: TimeInterval = 15 * 60

    var label: String?
    let latitude: Double
    let longitude: Double
    let accuracyMeters: Double?
    let precise: Bool
    let timeZone: TimeZone?
    let device: String?

    struct Invalid: Error, LocalizedError {
        var errorDescription: String? {
            "location must be {latitude, longitude} with optional label, accuracy, precise, timeZone, age and device."
        }
    }

    /// Parses a message's `location`. Throws for a malformed object; nil when it's absent or older
    /// than 15 minutes. Coordinates are rounded to 0.01° (about 1 km) unless `precise` is true.
    static func parse(_ value: Any?) throws -> RemoteClientLocation? {
        guard let value, !(value is NSNull) else { return nil }
        let allowed: Set<String> = ["label", "latitude", "longitude", "accuracy", "precise", "timeZone", "age", "device"]
        guard let object = value as? [String: Any], Set(object.keys).isSubset(of: allowed),
              let latitude = (object["latitude"] as? NSNumber)?.doubleValue,
              let longitude = (object["longitude"] as? NSNumber)?.doubleValue,
              latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { throw Invalid() }
        func optional<T>(_ key: String, as type: T.Type) throws -> T? {
            guard let raw = object[key], !(raw is NSNull) else { return nil }
            guard let typed = raw as? T else { throw Invalid() }
            return typed
        }
        let precise = try optional("precise", as: Bool.self) ?? false
        let accuracy = try optional("accuracy", as: NSNumber.self)?.doubleValue
        let age = try optional("age", as: NSNumber.self)?.doubleValue ?? 0
        guard accuracy.map({ $0.isFinite && $0 >= 0 }) ?? true, age.isFinite, age >= 0 else { throw Invalid() }
        guard age <= maximumAge else { return nil }
        let zone = try optional("timeZone", as: String.self).flatMap { $0.count <= 64 ? TimeZone(identifier: $0) : nil }
        let round = { (value: Double) in precise ? (value * 100_000).rounded() / 100_000 : (value * 100).rounded() / 100 }
        return RemoteClientLocation(
            label: try optional("label", as: String.self).flatMap(cleanLabel),
            latitude: round(latitude), longitude: round(longitude),
            accuracyMeters: precise ? accuracy : max(accuracy ?? 1_000, 1_000),
            precise: precise, timeZone: zone,
            device: try optional("device", as: String.self).flatMap(cleanDevice)
        )
    }

    /// Letters, digits, spaces and a few separators, at most 80 characters: a place name can't
    /// carry instructions or markup into the prompt.
    static func cleanLabel(_ raw: String) -> String? {
        let allowed = CharacterSet.letters.union(.decimalDigits).union(.nonBaseCharacters)
            .union(CharacterSet(charactersIn: " ,.'’-()/"))
        let kept = String(String.UnicodeScalarView(raw.unicodeScalars.map {
            allowed.contains($0) ? $0 : " "
        }))
        let collapsed = kept.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? nil : String(collapsed.prefix(80))
    }

    private static func cleanDevice(_ raw: String) -> String? {
        ["iPhone", "iPhone Duo", "iPad", "Mac", "Windows PC", "browser"].first { $0 == raw }
    }

    var coordinates: String {
        String(format: precise ? "%.5f, %.5f" : "%.2f, %.2f", latitude, longitude)
    }

    /// Fills a missing place name from the coordinates (Apple's geocoder, as for place cards),
    /// giving up after a few seconds; cached by coordinate for an hour.
    func named() async -> RemoteClientLocation {
        guard label == nil else { return self }
        var copy = self
        copy.label = await RemoteClientPlaceNames.shared.name(latitude: latitude, longitude: longitude)
        return copy
    }
}

@MainActor
final class RemoteClientPlaceNames {
    static let shared = RemoteClientPlaceNames()
    private var cache: [String: (name: String?, at: Date)] = [:]

    func name(latitude: Double, longitude: Double) async -> String? {
        let key = String(format: "%.2f,%.2f", latitude, longitude)
        if let hit = cache[key], Date().timeIntervalSince(hit.at) < 3_600 { return hit.name }
        let geocoder = CLGeocoder()
        let placemark: CLPlacemark? = await withTaskGroup(of: CLPlacemark?.self) { group in
            group.addTask {
                try? await geocoder.reverseGeocodeLocation(CLLocation(latitude: latitude, longitude: longitude)).first
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            geocoder.cancelGeocode()
            return first
        }
        let name = placemark.flatMap { mark in
            RemoteClientLocation.cleanLabel(
                [mark.locality ?? mark.subAdministrativeArea, mark.administrativeArea, mark.country]
                    .compactMap { $0 }.joined(separator: ", ")
            )
        }
        if cache.count > 64 { cache.removeAll() }
        cache[key] = (name, Date())
        return name
    }
}

/// A message from a paired client: the location it carried, or nil when the device shares none
/// (the model then uses the Mac's location and says so).
struct RemoteClientMessage: Equatable {
    let location: RemoteClientLocation?
}

/// The hidden note a paired client's message carries to the model: where the device is, or that
/// it shares no location and the Mac's is the fallback. Built when the message runs.
enum RemoteClientContextNote {
    static func note(for location: RemoteClientLocation?, macLocation: String?, now: Date = Date()) -> String {
        guard let location else {
            let mac = macLocation.map { "the Mac's location, \($0)" }
                ?? "the Mac's location (not known here; use the Mac's own network location if a tool needs one)"
            return "(Context: this message comes from a paired device that isn't sharing its location. "
                + "For anything that depends on where I am (weather, \"near me\", local time, places), use "
                + "\(mac), and say in your reply that you used the Mac's location. If my request doesn't "
                + "depend on location, ignore this and don't mention it.)"
        }
        let zone = location.timeZone ?? .current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "EEE MMM d, h:mm a"
        let place = location.label.map { "in \($0) (\(location.coordinates))" } ?? "at \(location.coordinates)"
        let accuracy = location.precise
            ? location.accuracyMeters.map { ", within about \(Int($0.rounded())) m" } ?? ""
            : ", rounded to about 1 km"
        let near = location.label ?? location.coordinates
        return "(Context: this message comes from my \(location.device ?? "paired device"), which is "
            + "\(place)\(accuracy); time zone \(zone.identifier), local time \(formatter.string(from: now)). "
            + "For anything that depends on where I am (weather, \"near me\", local time, places), use this "
            + "location, not the Mac's, and name the place you used in your reply. In a places block, set "
            + "\"near\" to \"\(near)\". Don't save this location in memory, notes, tasks or files. If my "
            + "request doesn't depend on location, ignore this and don't mention it.)"
    }
}
