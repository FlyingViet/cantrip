import Combine
import Foundation

/// The Apple Watch's optional internet route, off by default. When on, the voice API listens on
/// `127.0.0.1:8799` for signed watch requests only, and Tailscale Funnel publishes it at
/// `https://<this Mac>.<tailnet>.ts.net:10000`. Tailscale's config changes only when the setting
/// is switched; at launch Cantrip just restarts the listener and checks the Funnel is still there.
@MainActor
final class WatchInternetRoute: ObservableObject {
    static let shared = WatchInternetRoute()
    static let publicPort = 10_000
    static let defaultLocalPort = 8_799

    /// The public address while the route is on.
    @Published private(set) var url: String?
    /// What Settings says about the route, in words.
    @Published private(set) var status: String?
    @Published private(set) var working = false

    /// Runs the Tailscale CLI with these arguments; tests replace it.
    var run: (_ arguments: [String]) async -> (ok: Bool, output: String) = WatchInternetRoute.tailscale
    weak var server: RemoteControlServer?
    /// Where the voice-only listener runs on this Mac; tests use another port.
    var localPort = WatchInternetRoute.defaultLocalPort
    private var observers: Set<AnyCancellable> = []

    /// Follows the setting (and Remote control: the route needs it) from now on.
    func start(server: RemoteControlServer, settings: AppSettings = .shared) {
        self.server = server
        observers = []
        settings.$watchInternetRouteEnabled.removeDuplicates().dropFirst()
            .sink { [weak self] on in Task { @MainActor in await self?.apply(on: on && settings.remoteControlEnabled, switched: true) } }
            .store(in: &observers)
        settings.$remoteControlEnabled.removeDuplicates().dropFirst()
            .sink { [weak self] remote in
                Task { @MainActor in await self?.apply(on: remote && settings.watchInternetRouteEnabled, switched: false) }
            }
            .store(in: &observers)
        if settings.watchInternetRouteEnabled, settings.remoteControlEnabled {
            Task { await apply(on: true, switched: false) }
        }
    }

    /// `switched` is the user flipping the setting; only then does Cantrip change Tailscale's
    /// config (turning Funnel on or off). Otherwise it restarts or stops the listener and, when
    /// on, puts the Funnel back if it's missing.
    func apply(on: Bool, switched: Bool) async {
        working = true
        defer { working = false }
        guard on else {
            server?.stopVoiceListener()
            server?.internetVoiceURL = nil
            url = nil
            if switched {
                let result = await run(["funnel", "--yes", "--https=\(Self.publicPort)", "off"])
                status = result.ok || result.output.lowercased().contains("not found")
                    ? "Off. Port \(Self.publicPort) is no longer published."
                    : "Couldn't turn off the Funnel: \(Self.firstLine(result.output)). Run `tailscale funnel --https=\(Self.publicPort) off`."
            } else {
                status = nil
            }
            return
        }
        do {
            try server?.startVoiceListener(port: localPort)
        } catch {
            status = "Couldn't listen on 127.0.0.1:\(localPort): \(error.localizedDescription)"
            return
        }
        let state = await run(["serve", "status", "--json"])
        let target = "http://127.0.0.1:\(localPort)"
        let current = Self.funnel(in: state.output, port: Self.publicPort)
        var replaced: String?
        if current.proxy != target || !current.funnel {
            replaced = current.proxy.flatMap { $0 == target ? nil : $0 }
            let result = await run(["funnel", "--bg", "--yes", "--https=\(Self.publicPort)", target])
            guard result.ok else {
                server?.stopVoiceListener()
                status = "Couldn't publish port \(Self.publicPort) with Tailscale Funnel: \(Self.firstLine(result.output)). "
                    + "Funnel must be allowed for this Mac in your tailnet's policy."
                return
            }
        }
        guard let host = Self.dnsName(in: (await run(["status", "--json"])).output) else {
            status = "Funnel is on, but Cantrip couldn't read this Mac's Tailscale name."
            return
        }
        let address = "https://\(host):\(Self.publicPort)"
        url = address
        server?.internetVoiceURL = address
        status = "On: \(address) answers signed requests from your watches only."
            + (replaced.map { " It replaced the earlier Serve on that port (\($0))." } ?? "")
    }

    /// The proxy target served at `/` on `port`, and whether Funnel publishes it, from
    /// `tailscale serve status --json`.
    static func funnel(in json: String, port: Int) -> (proxy: String?, funnel: Bool) {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return (nil, false) }
        let web = object["Web"] as? [String: Any] ?? [:]
        let key = web.keys.first { $0.hasSuffix(":\(port)") }
        let handlers = key.flatMap { (web[$0] as? [String: Any])?["Handlers"] as? [String: Any] }
        let proxy = (handlers?["/"] as? [String: Any])?["Proxy"] as? String
        let allowed = (object["AllowFunnel"] as? [String: Bool] ?? [:]).contains { $0.key.hasSuffix(":\(port)") && $0.value }
        return (proxy, allowed)
    }

    /// This Mac's MagicDNS name from `tailscale status --json`, without the trailing dot.
    static func dnsName(in json: String) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let name = (object["Self"] as? [String: Any])?["DNSName"] as? String, !name.isEmpty else { return nil }
        return name.hasSuffix(".") ? String(name.dropLast()) : name
    }

    private static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.isEmpty ? "no answer" : String(line.prefix(200))
    }

    static let cliCandidates = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale",
                                "/usr/local/bin/tailscale"]

    static let tailscale: (_ arguments: [String]) async -> (ok: Bool, output: String) = { arguments in
        await Task.detached {
            guard let cli = cliCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                return (false, "Tailscale isn't installed on this Mac")
            }
            do {
                let result = try ProcessRunner.run(cli, arguments, errorOutput: .merge, timeout: 30)
                return (result.succeeded, result.text)
            } catch {
                return (false, error.localizedDescription)
            }
        }.value
    }
}
