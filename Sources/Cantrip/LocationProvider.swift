import Foundation
import CoreLocation

/// One-shot location with reverse geocoding, used to inject a context line
/// (e.g. "San Jose, CA, United States (37.335, -121.893)") into queries.
/// Triggers the standard macOS Location Services consent prompt on first use.
final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationProvider()
    @Published private(set) var contextLine: String?
    /// The last fix and its place name ("Santa Clara, CA, United States"), for weather cards.
    private(set) var lastCoordinate: CLLocationCoordinate2D?
    private(set) var placeName: String?

    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var lastFix: Date?

    override private init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// Request (or refresh) the current location. Safe to call often;
    /// re-fixes at most every 10 minutes.
    func refresh() {
        guard AppSettings.shared.shareLocation else { return }
        if let lastFix, Date().timeIntervalSince(lastFix) < 600, contextLine != nil { return }
        let status = manager.authorizationStatus
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization() // shows the system prompt
        } else if status == .authorizedAlways || status == .authorized {
            manager.requestLocation()
        } else {
            Log.write("location: not authorized (status=\(status.rawValue))")
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Log.write("location: authorization changed (status=\(status.rawValue))")
        if status == .authorizedAlways || status == .authorized {
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        lastFix = Date()
        lastCoordinate = loc.coordinate
        let coord = String(format: "%.3f, %.3f", loc.coordinate.latitude, loc.coordinate.longitude)
        geocoder.reverseGeocodeLocation(loc) { [weak self] placemarks, _ in
            DispatchQueue.main.async {
                if let pm = placemarks?.first {
                    let parts = [pm.locality, pm.administrativeArea, pm.country].compactMap { $0 }
                    self?.placeName = parts.isEmpty ? nil : parts.joined(separator: ", ")
                    self?.contextLine = parts.isEmpty ? coord : "\(parts.joined(separator: ", ")) (\(coord))"
                } else {
                    self?.contextLine = coord
                }
                Log.write("location: fix acquired")
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Log.write("location error: \(error.localizedDescription)")
    }
}

extension WeatherCardResolver {
    /// The Mac's own location for weather cards, while "Share my location as context" is on.
    @MainActor
    static func macPlace() -> KnownPlace? {
        guard AppSettings.shared.shareLocation else { return nil }
        let provider = LocationProvider.shared
        provider.refresh()
        return provider.lastCoordinate.map {
            KnownPlace(label: provider.placeName, coordinate: Coordinate(latitude: $0.latitude, longitude: $0.longitude),
                       note: "The Mac's location")
        }
    }

    /// `cantrip weather [PLACE]`: no device here, so a missing place means the Mac's location.
    @MainActor
    static func cliForecast(place: String?) async -> WeatherCard {
        await shared.resolve(WeatherBlockProposal(place: place.flatMap(WeatherBlock.clean)),
                             context: Context(device: nil, mac: macPlace(), unit: preferredUnit))
    }
}
