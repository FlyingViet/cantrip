import CoreLocation
import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Where this device is, as sent with one message (`location` on `POST …/messages`).
struct CantripClientLocation: Encodable, Equatable {
    let latitude: Double
    let longitude: Double
    let label: String?
    let accuracy: Double?
    let precise: Bool
    let timeZone: String
    /// Seconds since the fix; the Mac ignores one older than 15 minutes.
    let age: Int
    let device: String

    /// Coarse fixes are rounded to 0.01° (about 1 km) before they leave the device.
    static func make(_ location: CLLocation, label: String?, precise: Bool, device: String,
                     now: Date = Date(), timeZone: TimeZone = .current) -> CantripClientLocation {
        let round = { (value: Double) in precise ? (value * 100_000).rounded() / 100_000 : (value * 100).rounded() / 100 }
        let accuracy = location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil
        return CantripClientLocation(
            latitude: round(location.coordinate.latitude), longitude: round(location.coordinate.longitude),
            label: label, accuracy: precise ? accuracy.map { $0.rounded() } : max(accuracy ?? 1_000, 1_000).rounded(),
            precise: precise, timeZone: timeZone.identifier,
            age: max(0, Int(now.timeIntervalSince(location.timestamp).rounded())), device: device
        )
    }
}

/// Settings › Location: "Share location with messages" (off by default). While it's on, each
/// message carries this device's location: When In Use permission only, one fix at a time when a
/// message is sent (never in the background), reused for up to 15 minutes, about 1 km unless
/// Precise is on. It goes only to the paired Mac, with that message.
@MainActor
final class CantripLocationSharing: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = CantripLocationSharing()
    static let enabledKey = "cantrip.location.share"
    static let preciseKey = "cantrip.location.precise"
    static let maximumAge: TimeInterval = 15 * 60
    /// Tests replace this to send a fixed location (or none).
    static var provider: () async -> CantripClientLocation? = { await shared.locationForMessage() }

    enum State: Equatable {
        case off, needsPermission, denied, finding, unavailable
        case found(String)
    }

    @Published private(set) var state: State = .off

    private lazy var manager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.delegate = self
        return manager
    }()
    private let geocoder = CLGeocoder()
    private var fix: (location: CLLocation, label: String?, precise: Bool)?
    private var waiters: [CheckedContinuation<CLLocation?, Never>] = []
    private var request = 0

    static var deviceName: String {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #else
        "Mac"
        #endif
    }

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }
    var isPrecise: Bool { UserDefaults.standard.bool(forKey: Self.preciseKey) }

    private var isAuthorized: Bool {
        switch manager.authorizationStatus {
        case .authorizedAlways: return true
        #if os(iOS)
        case .authorizedWhenInUse: return true
        #endif
        default: return false
        }
    }

    /// Settings turned sharing on, or changed precision: ask for permission, then find the place.
    func settingsChanged() {
        fix = nil
        guard isEnabled else {
            state = .off
            return
        }
        switch manager.authorizationStatus {
        case .notDetermined:
            state = .needsPermission
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            state = .denied
        default:
            Task { _ = await currentFix() }
        }
    }

    /// The location for the message being sent; nil while sharing is off, not allowed, or no fix
    /// arrives within a few seconds (the Mac's location stands in, and the reply says so).
    func locationForMessage() async -> CantripClientLocation? {
        guard isEnabled, let fix = await currentFix() else { return nil }
        return CantripClientLocation.make(fix.location, label: fix.label, precise: fix.precise, device: Self.deviceName)
    }

    private func currentFix() async -> (location: CLLocation, label: String?, precise: Bool)? {
        let precise = isPrecise
        if let fix, fix.precise == precise, Date().timeIntervalSince(fix.location.timestamp) < Self.maximumAge {
            return fix
        }
        guard isAuthorized else {
            state = manager.authorizationStatus == .notDetermined ? .needsPermission : .denied
            if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
            return nil
        }
        state = .finding
        manager.desiredAccuracy = precise ? kCLLocationAccuracyBest : kCLLocationAccuracyKilometer
        guard let location = await oneLocation(timeout: precise ? 8 : 5) else {
            state = .unavailable
            return nil
        }
        let label = await placeName(location)
        let newFix = (location: location, label: label, precise: precise)
        if isEnabled, isPrecise == precise { fix = newFix }
        state = .found(label ?? String(format: "%.2f, %.2f", location.coordinate.latitude, location.coordinate.longitude))
        return newFix
    }

    private func oneLocation(timeout: TimeInterval) async -> CLLocation? {
        request += 1
        let current = request
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
            if waiters.count == 1 { manager.requestLocation() }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self, self.request == current else { return }
                self.resolve(nil)
            }
        }
    }

    private func resolve(_ location: CLLocation?) {
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume(returning: location) }
    }

    /// "Mountain View, CA, United States", from Apple's geocoder; nil if it doesn't answer.
    private func placeName(_ location: CLLocation) async -> String? {
        guard let mark = try? await geocoder.reverseGeocodeLocation(location).first else { return nil }
        let parts = [mark.locality ?? mark.subAdministrativeArea, mark.administrativeArea, mark.country].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let latest = locations.last
        Task { @MainActor in self.resolve(latest) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.resolve(nil) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.isEnabled else { return }
            switch manager.authorizationStatus {
            case .notDetermined: self.state = .needsPermission
            case .denied, .restricted: self.state = .denied
            default: if self.fix == nil { _ = await self.currentFix() }
            }
        }
    }
}

/// Settings › Location.
struct SettingsLocationPage: View {
    @ObservedObject var remote: CantripRemoteModel
    @ObservedObject private var sharing = CantripLocationSharing.shared
    @AppStorage(CantripLocationSharing.enabledKey) private var enabled = false
    @AppStorage(CantripLocationSharing.preciseKey) private var precise = false

    var body: some View {
        Form {
            Section { SettingsScopeLabel.thisDevice() }
            // Cantrip's own window on the Mac: this Mac's location for the panel's prompts.
            SettingsManifestSections(page: "location")
            Section {
                Toggle(isOn: $enabled) {
                    Label("Share location with messages", systemImage: "location")
                }
                .accessibilityIdentifier("settings.location.share")
                Toggle(isOn: $precise) {
                    Label("Precise location", systemImage: "scope")
                }
                .disabled(!enabled)
                .accessibilityIdentifier("settings.location.precise")
            } footer: {
                Text("Off by default. While on, each message you send includes this device's location, rounded to about 1 km unless Precise location is on, and its time zone, so weather and \"near me\" answers are for where you are. It goes only to \(remote.macName) over your paired connection and isn't saved in Cantrip's memory. While off, Cantrip uses the Mac's location and says so.")
            }
            if enabled {
                Section {
                    LabeledContent("Current location") {
                        Text(Self.status(sharing.state))
                            .multilineTextAlignment(.trailing)
                    }
                    .accessibilityIdentifier("settings.location.status")
                    if sharing.state == .denied {
                        Button("Open Location Settings") { Self.openSystemSettings() }
                            .accessibilityIdentifier("settings.location.openSystemSettings")
                    }
                } footer: {
                    if remote.selectedSession != nil, remote.selectedSession?.supportsClientLocation != true {
                        Text("Update Cantrip on \(remote.macName) to use this device's location; until then it uses the Mac's.")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Location")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if enabled { sharing.settingsChanged() } }
        .onChange(of: enabled) { _, _ in sharing.settingsChanged() }
        .onChange(of: precise) { _, _ in sharing.settingsChanged() }
    }

    static func status(_ state: CantripLocationSharing.State) -> String {
        switch state {
        case .off: return "Off"
        case .needsPermission: return "Allow location access to share it"
        case .denied: return "Location access is off for this app"
        case .finding: return "Finding…"
        case .unavailable: return "Location isn't available right now"
        case .found(let place): return place
        }
    }

    private static func openSystemSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        #else
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }
}
