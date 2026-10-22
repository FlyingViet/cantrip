import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The link `cantrip pair` prints (as a QR code) on a Cantrip host:
/// `cantripagent://pair?v=1&name=<label>&token=<token>[&url=<https>][&direct=<host:port>][&tailscaleOnly=1]`.
/// Opening it only asks for confirmation; nothing is saved until the user taps Pair.
struct CantripPairingLink: Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    static let host = "pair"
    static let version = 1
    private static let fields: Set<String> = ["v", "name", "token", "url", "direct", "tailscaleOnly"]

    /// The host's own label, e.g. its hostname. Display only: anyone can print a link.
    let name: String?
    let token: String
    /// Normalized HTTPS origin, as Settings saves it.
    let url: String?
    let directAddress: String?
    let tailscaleOnly: Bool

    /// The saved server's name, defaulted the way Settings' Add Server does.
    var displayName: String {
        name ?? url.flatMap { URL(string: $0)?.host } ?? directAddress ?? "Cantrip on LAN"
    }

    var urlHost: String? {
        guard let url, let components = URLComponents(string: url), let host = components.host else { return nil }
        return components.port.map { "\(host):\($0)" } ?? host
    }

    var tokenSuffix: String { String(token.suffix(4)) }
    var description: String { "CantripPairingLink(\(displayName), token ending \(tokenSuffix))" }
    var debugDescription: String { description }

    var draft: ServerDraft {
        ServerDraft(name: name ?? "", url: url ?? "", credential: token, tailscaleOnly: tailscaleOnly,
                    directAddress: directAddress ?? "")
    }

    /// Nil when `link` isn't a pairing link, so other deep links keep their own handling.
    @MainActor
    static func parse(_ link: URL) -> Result<CantripPairingLink, CantripPairingLinkError>? {
        guard link.scheme?.lowercased() == CantripDeepLink.scheme,
              let components = URLComponents(url: link, resolvingAgainstBaseURL: false),
              components.host?.lowercased() == host else { return nil }
        do {
            return .success(try parse(components))
        } catch let error as CantripPairingLinkError {
            return .failure(error)
        } catch {
            return .failure(.malformed)
        }
    }

    @MainActor
    private static func parse(_ components: URLComponents) throws -> CantripPairingLink {
        guard components.path.isEmpty || components.path == "/", components.fragment == nil else {
            throw CantripPairingLinkError.malformed
        }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] where fields.contains(item.name) {
            // Two tokens or URLs would be ambiguous.
            guard query[item.name] == nil else { throw CantripPairingLinkError.malformed }
            query[item.name] = item.value ?? ""
        }
        guard let version = query["v"].flatMap(Int.init), version >= 1 else {
            throw CantripPairingLinkError.malformed
        }
        guard version == Self.version else { throw CantripPairingLinkError.unsupportedVersion }
        let token = query["token"] ?? ""
        guard (32...128).contains(token.count),
              token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw CantripPairingLinkError.invalidToken
        }
        let url: String?
        do {
            url = try CantripRemoteModel.normalizedBaseURL(query["url"] ?? "")?.absoluteString
        } catch {
            throw CantripPairingLinkError.invalidURL(error.localizedDescription)
        }
        let direct: String?
        do {
            direct = try CantripDirectAddress.normalized(query["direct"])
        } catch {
            throw CantripPairingLinkError.invalidDirectAddress
        }
        let tailscaleOnly: Bool
        switch query["tailscaleOnly"] {
        case nil, "0": tailscaleOnly = false
        case "1": tailscaleOnly = true
        default: throw CantripPairingLinkError.malformed
        }
        guard !tailscaleOnly || url != nil else { throw CantripPairingLinkError.tailscaleOnlyWithoutURL }
        return CantripPairingLink(name: label(query["name"]), token: token, url: url,
                                  directAddress: direct, tailscaleOnly: tailscaleOnly)
    }

    /// One line of at most 80 characters, without control or bidi-format characters that could
    /// disguise which host it is.
    private static func label(_ raw: String?) -> String? {
        let words = (raw ?? "").split { character in
            character.isWhitespace || character.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        let name = String(words.joined(separator: " ").prefix(80)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}

enum CantripPairingLinkError: LocalizedError, Equatable {
    case unsupportedVersion
    case malformed
    case invalidToken
    case invalidURL(String)
    case invalidDirectAddress
    case tailscaleOnlyWithoutURL

    #if os(macOS)
    static let appName = "Cantrip Gateway"
    #else
    static let appName = "Cantrip Agent"
    #endif
    private static let retry = "Run cantrip pair on the host again."

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion:
            return "Update \(Self.appName) to pair with this Mac."
        case .malformed:
            return "This pairing link is incomplete or damaged. \(Self.retry)"
        case .invalidToken:
            return "This pairing link's token is invalid. \(Self.retry)"
        case .invalidURL(let reason):
            return "This pairing link's URL can't be used. \(reason)"
        case .invalidDirectAddress:
            return "This pairing link's direct address must be host:port, for example \(CantripDirectAddress.example)."
        case .tailscaleOnlyWithoutURL:
            return "This pairing link is set to Tailscale only but has no HTTPS URL. \(Self.retry)"
        }
    }
}

/// A pairing link waiting for the user, or why it can't be used.
struct CantripPairingPrompt: Identifiable {
    let id = UUID()
    let result: Result<CantripPairingLink, CantripPairingLinkError>

    var link: CantripPairingLink? { try? result.get() }
}

extension CantripRemoteModel {
    /// The saved server a link matches (same routes and token), selected instead of adding a duplicate.
    func savedServer(for link: CantripPairingLink) -> SavedServer? {
        servers.servers.first {
            $0.url == (link.url ?? "") && $0.directAddress == link.directAddress
                && (try? servers.credential(for: $0)) == link.token
        }
    }

    /// Pairs from a confirmed link the way Settings does: Add Server (unless the identical server
    /// is saved), then select it, which configures the connection. A failed switch saves nothing.
    @discardableResult
    func pair(with link: CantripPairingLink) async throws -> SavedServer {
        guard !isMutating, !isUploadingVideo, !isUpdatingNotifications else {
            throw ServerConfigurationError(message: "Wait for the current request to finish before pairing.")
        }
        let existing = savedServer(for: link)
        let server = try existing ?? servers.add(link.draft)
        do {
            try await selectServer(server)
        } catch {
            if existing == nil { try? servers.remove(server) }
            throw error
        }
        return server
    }
}

/// Confirms a pairing link: the host, its routes and what happens to the current connection.
/// Pair saves it like Settings' Add Server and connects; Cancel saves nothing.
struct CantripPairingView: View {
    let prompt: CantripPairingPrompt
    @ObservedObject var model: CantripRemoteModel
    /// Closes the confirmation; true once paired.
    let close: (Bool) -> Void
    @State private var pairing = false
    @State private var failure: String?
    @State private var saved: SavedServer?

    var body: some View {
        NavigationStack {
            Form {
                if let link = prompt.link {
                    CantripPairingSummary(link: link, effect: effect(link))
                    status
                } else if case .failure(let error) = prompt.result {
                    Section {
                        CantripPairingNotice(message: error.localizedDescription)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(prompt.link == nil ? "Can't Pair" : "Pair with Cantrip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        .interactiveDismissDisabled(pairing)
        .task {
            if let link = prompt.link { saved = model.savedServer(for: link) }
        }
    }

    @ViewBuilder private var status: some View {
        if pairing || failure != nil {
            Section {
                if pairing { ProgressView("Pairing...") }
                if let failure { CantripPairingNotice(message: failure) }
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if let link = prompt.link {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { close(false) }
                    .disabled(pairing)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Pair") { pair(link) }
                    .disabled(pairing)
                    .accessibilityHint("Saves \(link.displayName) and connects to it")
            }
        } else {
            ToolbarItem(placement: .confirmationAction) {
                Button("OK") { close(false) }
            }
        }
    }

    private func effect(_ link: CantripPairingLink) -> String {
        if let saved, saved.id == model.selectedServerID {
            return "Already paired as \(saved.name). Pair keeps this connection."
        }
        if let saved {
            return "Already saved as \(saved.name). Pair switches to it."
        }
        if let current = model.servers.selected {
            return "Pair adds \(link.displayName) to your saved servers and switches to it. \(current.name) stays saved; switch back in Settings."
        }
        return "Pair adds \(link.displayName) to your saved servers and connects to it."
    }

    private func pair(_ link: CantripPairingLink) {
        guard !pairing else { return }
        pairing = true
        failure = nil
        Task {
            do {
                try await model.pair(with: link)
                pairing = false
                close(true)
            } catch {
                pairing = false
                failure = error.localizedDescription
                AccessibilityNotification.Announcement(error.localizedDescription).post()
            }
        }
    }
}

private struct CantripPairingSummary: View {
    let link: CantripPairingLink
    let effect: String

    var body: some View {
        Section {
            SavedServerRow(server: preview, isSelected: false)
        } header: {
            Text("Host")
        } footer: {
            Text("Pair only with a computer you control. Everything you send runs there.")
        }
        Section {
            if let host = link.urlHost {
                CantripPairingRouteRow(icon: "lock", title: "HTTPS", value: Text(host))
            }
            if let direct = link.directAddress {
                CantripPairingRouteRow(icon: "point.3.connected.trianglepath.dotted", title: "Direct address",
                                       value: Text("\(direct), encrypted"))
            }
            CantripPairingRouteRow(icon: "wifi", title: "Local network",
                                   value: Text(link.tailscaleOnly ? "Not used (Tailscale only)" : "Found automatically on the same network"))
            CantripPairingRouteRow(icon: "key", title: "Pairing token",
                                   value: Text("Ends in \(Text(link.tokenSuffix).speechSpellsOutCharacters())"))
        } header: {
            Text("Routes")
        } footer: {
            if link.url == nil, link.directAddress == nil {
                Text("Without a URL or direct address, \(link.displayName) is reachable only on the same network.")
            }
        }
        Section {
            Label {
                Text(effect)
            } icon: {
                Image(systemName: "arrow.triangle.swap").foregroundStyle(.tint)
            }
        }
    }

    private var preview: SavedServer {
        SavedServer(id: UUID(), name: link.displayName, url: link.url ?? "", tailscaleOnly: link.tailscaleOnly,
                    usesLegacyHistory: false, directAddress: link.directAddress)
    }
}

private struct CantripPairingRouteRow: View {
    let icon: String
    let title: String
    let value: Text
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            // Accessibility sizes give the value the row's full width instead of a column beside the icon.
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Label { titleText } icon: { iconImage }
                    valueText
                }
            } else {
                Label {
                    VStack(alignment: .leading, spacing: 2) { titleText; valueText }
                } icon: { iconImage }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var titleText: some View { Text(title).font(.subheadline).foregroundStyle(.secondary) }
    private var valueText: some View { value }
    private var iconImage: some View { Image(systemName: icon).foregroundStyle(.tint).accessibilityHidden(true) }
}

/// Primary-colored text keeps errors readable in light and dark; the icon carries the warning color.
private struct CantripPairingNotice: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .accessibilityElement(children: .combine)
    }
}

#if os(iOS)
/// Presents the confirmation over whatever is on screen (Settings included), like the image viewer,
/// so a link opened from the Camera never waits for another sheet to close.
@MainActor
enum CantripPairingPresenter {
    private static weak var current: UIViewController?

    @discardableResult
    static func present(_ prompt: CantripPairingPrompt, model: CantripRemoteModel,
                        onPaired: @escaping () -> Void) -> UIHostingController<CantripPairingView> {
        final class Holder { weak var controller: UIViewController? }
        let holder = Holder()
        let host = UIHostingController(rootView: CantripPairingView(prompt: prompt, model: model) { paired in
            holder.controller?.dismiss(animated: true)
            if paired { onPaired() }
        })
        host.overrideUserInterfaceStyle = .dark
        if prompt.link == nil { host.sheetPresentationController?.detents = [.medium(), .large()] }
        holder.controller = host
        let show = {
            guard let presenter = CantripImageViewerPresenter.topViewController() else { return }
            current = host
            presenter.present(host, animated: true)
        }
        // A newer link replaces one still open.
        if let current, current.presentingViewController != nil, !current.isBeingDismissed {
            current.dismiss(animated: false, completion: show)
        } else {
            show()
        }
        return host
    }
}
#endif
