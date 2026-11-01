import SwiftUI

/// Settings › Remote control › Apple Watch: the watches that may talk to Home by voice, and the
/// optional internet route.
struct AppleWatchSettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var route = WatchInternetRoute.shared
    var registry = WatchDeviceRegistry.shared
    @State private var devices: [WatchDevice] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Apple Watch").font(.caption.weight(.semibold))
            if devices.isEmpty {
                Text("No watches yet. Open Cantrip on the watch and tap Set Up with the iPhone nearby.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            ForEach(devices) { device in
                HStack(spacing: 6) {
                    Image(systemName: "applewatch").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(device.name).font(.caption).lineLimit(1)
                        Text(Self.lastUse(device)).font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 6)
                    Button("Remove") {
                        _ = try? registry.remove(device.id)
                        reload()
                    }
                    .font(.caption2)
                    .help("This watch can't reach Cantrip again until it's set up again with the iPhone.")
                    .accessibilityLabel("Remove \(device.name)")
                }
            }
            Toggle("Reach Home from the watch over the internet", isOn: $settings.watchInternetRouteEnabled)
                .font(.caption)
                .toggleStyle(.checkbox)
                .disabled(route.working)
            Text("Off: the watch reaches this Mac through your iPhone's Tailscale. On: Tailscale Funnel publishes port \(WatchInternetRoute.publicPort) to the internet for signed requests from these watches only (voice requests to Home, nothing else), so a watch on its own Wi-Fi or cellular works too.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let status = route.status {
                Text(status).font(.caption2)
                    .foregroundStyle(status.hasPrefix("Couldn't") ? Color.orange : Color.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: WatchDeviceRegistry.changed)) { _ in reload() }
    }

    private func reload() { devices = registry.all.sorted { $0.addedAt < $1.addedAt } }

    static func lastUse(_ device: WatchDevice) -> String {
        guard let used = device.lastUsedAt else { return "Added \(device.addedAt.formatted(date: .abbreviated, time: .omitted)), not used yet" }
        return "Last used \(used.formatted(.relative(presentation: .named)))"
    }
}
