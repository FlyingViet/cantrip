import SwiftUI

/// Settings' pages, in the same order on iPhone, iPhone Duo and Gateway Mac.
enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case macs, models, tools, memory, voice, location, notifications, appearance, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .macs: return "Macs"
        case .models: return "Models"
        case .tools: return "Tools & sign-ins"
        case .memory: return "Memory"
        case .voice: return "Voice"
        case .location: return "Location"
        case .notifications: return "Notifications"
        case .appearance: return "Appearance"
        case .about: return "About & Updates"
        }
    }

    var systemImage: String {
        switch self {
        case .macs: return "desktopcomputer"
        case .models: return "cpu"
        case .tools: return "puzzlepiece.extension"
        case .memory: return "brain"
        case .voice: return "waveform"
        case .location: return "location.fill"
        case .notifications: return "bell.badge"
        case .appearance: return "paintpalette"
        case .about: return "info.circle"
        }
    }

    var tint: Color {
        switch self {
        case .macs: return .blue
        case .models: return .purple
        case .tools: return .orange
        case .memory: return .pink
        case .voice: return .indigo
        case .location: return .green
        case .notifications: return .red
        case .appearance: return .teal
        case .about: return .gray
        }
    }

    /// One line under the page's row.
    var summary: String {
        switch self {
        case .macs: return "Pair, switch and remove Macs"
        case .models: return "Model tiers, backups and usage limits"
        case .tools: return "Backends, GitHub and MCP servers, and their sign-ins"
        case .memory: return "What Cantrip remembers on your Mac"
        case .voice: return "Speech recognition and reply voice"
        case .location: return "Answers for where this device is"
        case .notifications: return "Alerts, widget and Live Activity"
        case .appearance: return "Mascot and reply steps"
        case .about: return "Version, updates, Mac permissions and skills"
        }
    }

    /// The pages this device shows: the Mac has no push alerts or Live Activities.
    static var available: [SettingsPage] {
        #if os(macOS)
        allCases.filter { $0 != .notifications }
        #else
        allCases
        #endif
    }

    /// The last page opened, shown again beside the list where Settings shows both.
    static let lastPageKey = "cantrip.settings.lastPage"
}

/// Who a setting changes, shown at the top of each page.
struct SettingsScopeLabel: View {
    let text: String
    let systemImage: String

    static func thisDevice() -> SettingsScopeLabel {
        #if os(macOS)
        SettingsScopeLabel(text: "This Mac", systemImage: "laptopcomputer")
        #else
        SettingsScopeLabel(text: "This device", systemImage: "iphone")
        #endif
    }

    static func allTabs(on mac: String) -> SettingsScopeLabel {
        SettingsScopeLabel(text: "All tabs on \(mac)", systemImage: "rectangle.stack")
    }

    static func thisTab() -> SettingsScopeLabel {
        SettingsScopeLabel(text: "This tab", systemImage: "rectangle")
    }

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Applies to: \(text)")
            .accessibilityIdentifier("settings.scope")
    }
}

extension CantripRemoteModel {
    /// The paired Mac's name for scope labels and the status card.
    var macName: String { servers.selected?.name ?? "your Mac" }
}

/// The top of Settings: which Mac this device uses and how it reaches it, what new tabs run on,
/// and the usage-limit backups.
struct SettingsStatusCard: View {
    @ObservedObject var remote: CantripRemoteModel
    let fallback: CantripUsageFallback?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 34)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(remote.servers.selected?.name ?? "No Mac paired")
                        .font(.headline)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(remote.isConnected ? Color.green : Color.secondary)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text(remote.servers.selected == nil ? "Pair a Mac to start" : remote.routeLabel)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let fallback {
                SettingsStatusLine(title: "Runs on", value: Self.model(fallback))
                SettingsStatusLine(title: "Backups", value: Self.backups(fallback))
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.status")
    }

    /// "Copilot · claude-opus-5.5", or just the backend when it has no model picker.
    static func model(_ fallback: CantripUsageFallback) -> String {
        let model = fallback.primaryChoice?.defaultModel
        return [fallback.primary, model].compactMap { $0 }.joined(separator: " · ")
    }

    /// "Claude Code, then Antigravity · Deep", "Off", and how many are at their limit.
    static func backups(_ fallback: CantripUsageFallback) -> String {
        guard !fallback.chain.isEmpty else { return "Off" }
        let names = fallback.rows.map { entry -> String in
            // The Mac's label names what runs now and why; the card keeps the backend and its pick.
            let model = ["fast", "standard", "deep"].contains(entry.model) ? CantripModelTiers.label(entry.model) : entry.model
            let name = model.isEmpty ? entry.backend : "\(entry.backend) · \(model)"
            return entry.limitedUntilLabel == nil ? name : "\(name) (at its limit)"
        }
        return names.joined(separator: ", then ")
    }
}

/// Pause Agent, under the status card: app-wide, so it lives in Settings rather than a tab's menu.
/// While it's on, chat shows "Agent paused" with Resume in place of the composer.
struct SettingsPauseRow: View {
    @AppStorage("hermes.paused") private var paused = false

    var body: some View {
        // The caption sits under the switch's row so it wraps in Gateway Mac's narrow sidebar too.
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Pause Agent", isOn: $paused)
                .toggleStyle(.switch)
                .tint(.orange)
                .accessibilityHint(Self.caption(paused))
                .accessibilityIdentifier("settings.pause")
            Text(Self.caption(paused))
                .font(.caption)
                .foregroundStyle(paused ? Color.orange : Color.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
        }
    }

    static func caption(_ paused: Bool) -> String {
        paused ? "Paused. This device sends nothing until you turn this off or tap Resume in chat."
            : "Stops every request from this device, on every tab, until you turn it off."
    }
}

private struct SettingsStatusLine: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

/// One page's row in Settings' list: a tinted icon, its name and a line on what it holds.
struct SettingsPageRow: View {
    let page: SettingsPage

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: page.systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(page.tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(page.title)
                Text(page.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.page.\(page.rawValue)")
    }
}
