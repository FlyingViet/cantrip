import AppKit
import SwiftUI

/// The app's side of the secrets broker: the names-only index for Settings and paired clients,
/// syncs started from either (the password dialog always appears on the Mac), and the values
/// Cantrip masks in its own log and run journals.
@MainActor
final class SecretsHub: ObservableObject {
    static let shared = SecretsHub()

    @Published private(set) var index = SecretIndex()
    @Published private(set) var syncing = false
    /// Who asked for the sync in progress, such as "Settings" or "a paired client".
    @Published private(set) var requestedBy: String?
    @Published private(set) var lastReport: String?
    private var modified: Date?
    private var timer: Timer?

    var bitwardenPath: String? { BitwardenCLI.locate() }

    /// Loads the index and the values to mask, and notices syncs made from the command line.
    func start() {
        reload(force: true)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            Task { @MainActor in SecretsHub.shared.reload() }
        }
    }

    func reload(force: Bool = false) {
        let url = SecretIndex.file
        let changed = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard force || changed != modified else { return }
        modified = changed
        let previous = index.lastSync
        index = SecretIndex.load(from: url) ?? SecretIndex()
        guard force || index.lastSync != previous else { return }
        // Nothing synced yet: don't touch the keychain at all.
        if index.items.isEmpty { SecretRedaction.update([]) } else { Self.reloadRedaction() }
    }

    nonisolated static func reloadRedaction() {
        DispatchQueue.global(qos: .utility).async {
            do {
                SecretRedaction.update(try SecretKeychain.Store.keychain.allItems().flatMap(\.maskedValues))
            } catch {
                Log.write("secrets: masking unavailable: \(error.localizedDescription)")
            }
        }
    }

    /// Unlocks Bitwarden with a dialog on the Mac and refreshes the cache. Paired clients can ask
    /// for this; only someone at the Mac can answer it.
    func requestSync(from source: String) {
        guard !syncing else { return }
        guard let path = bitwardenPath else {
            lastReport = "The Bitwarden CLI (bw) isn't installed on this Mac."
            return
        }
        syncing = true
        requestedBy = source
        lastReport = nil
        Log.write("secrets: sync requested from \(source)")
        let reason = "Cantrip is syncing its secrets (asked from \(source))."
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: String
            do {
                let report = try SecretSync.run(bitwarden: .live(path), password: { try SecretPasswordDialog.ask(reason: reason) })
                outcome = "Synced \(report.cached.count) secret(s)." + (report.skipped.isEmpty ? "" : " Skipped \(report.skipped.count).")
            } catch {
                outcome = error.localizedDescription
            }
            Log.write("secrets: \(outcome)")
            DispatchQueue.main.async {
                let hub = SecretsHub.shared
                hub.syncing = false
                hub.requestedBy = nil
                hub.lastReport = outcome
                hub.reload(force: true)
            }
        }
    }

    /// Names, field names and sync state for paired clients. Never a value.
    func remotePayload() -> [String: Any] {
        reload()
        var payload = index.remotePayload
        payload["syncing"] = syncing
        payload["available"] = bitwardenPath != nil
        if let requestedBy { payload["requestedBy"] = requestedBy }
        if let lastReport { payload["lastReport"] = lastReport }
        return payload
    }
}

/// Settings > Secrets: what the broker holds (names only), when it last synced, and a button to
/// unlock Bitwarden and sync now.
struct SecretsView: View {
    @ObservedObject var hub = SecretsHub.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Secrets").font(.caption.weight(.semibold))
            Text("Bitwarden's “\(hub.index.folder)” folder is the source; the keychain keeps a copy so scheduled jobs work while the vault is locked. Commands get values with `cantrip secret run NAME -- command`; models and paired devices only see names.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(status).font(.caption)
                Spacer()
                if hub.syncing {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the password dialog…").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Button("Unlock & Sync") { hub.requestSync(from: "Settings") }
                        .font(.caption)
                        .disabled(hub.bitwardenPath == nil)
                }
            }
            if hub.bitwardenPath == nil {
                Text("Install the Bitwarden CLI (brew install bitwarden-cli) and log in once with `bw login`.")
                    .font(.caption2).foregroundStyle(.orange)
            }
            if let report = hub.lastReport { Text(report).font(.caption2).foregroundStyle(.secondary) }
            if let error = hub.index.lastError { Text(error).font(.caption2).foregroundStyle(.orange) }
            ForEach(hub.index.items) { item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.name).font(.caption2.monospaced())
                    Text(item.kind == .fields ? item.fields.joined(separator: " ") : item.kind.rawValue)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            ForEach(hub.index.skipped, id: \.self) { Text("Skipped \($0)").font(.caption2).foregroundStyle(.orange) }
        }
        .onAppear { hub.reload(force: true) }
    }

    private var status: String {
        let count = hub.index.items.count
        guard let lastSync = hub.index.lastSync else { return count == 0 ? "Not synced yet" : "\(count) secrets" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "\(count) secret\(count == 1 ? "" : "s") · synced \(formatter.localizedString(for: lastSync, relativeTo: Date()))"
    }
}
