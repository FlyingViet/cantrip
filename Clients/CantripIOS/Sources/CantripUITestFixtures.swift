#if DEBUG
import SwiftUI
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

/// Debug-only screens that UI tests launch directly (`-CantripUITestImageViewer`), so real
/// touches can exercise the image viewer without a paired Mac. Never compiled into Release.
enum CantripUITestFixtures {
    static var showsImageViewer: Bool {
        ProcessInfo.processInfo.arguments.contains("-CantripUITestImageViewer")
    }

    /// `-CantripUITestRequestBadges` asks for alert and badge permission at launch, as turning on
    /// Cantrip alerts would, so badge tests run without a paired Mac's push setup.
    static func requestBadgesIfAsked() async {
        guard ProcessInfo.processInfo.arguments.contains("-CantripUITestRequestBadges") else { return }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    static var pairsWithFixtureHost: Bool {
        ProcessInfo.processInfo.arguments.contains("-CantripUITestRemoteURL")
    }

    /// Face ID can't be satisfied from a UI test on the simulator; only fixture-host runs skip it.
    static let authorizeSensitiveAction: (String) async throws -> Void = { reason in
        if pairsWithFixtureHost { return }
        try await CantripBiometrics.authorize(reason)
    }

    /// `-CantripUITestBackendCommands` answers every session's `/commands` call with the generic
    /// contract fixture (and treats every session as listing commands), so "/" suggestions show
    /// against fixture hosts that don't serve the route.
    static let backendCommands: BackendCommandsResponse? = {
        guard ProcessInfo.processInfo.arguments.contains("-CantripUITestBackendCommands") else { return nil }
        return try? JSONDecoder().decode(BackendCommandsResponse.self, from: Data(backendCommandsJSON.utf8))
    }()

    /// The generic fixture from the host contract. Never put real skill names here.
    static let backendCommandsJSON = """
    {"backend":"Copilot","workdir":"/tmp/project","revision":"r1","status":null,"commands":[
     {"name":"plan","description":"Create an implementation plan before coding","kind":"builtin","source":"Copilot","inputHint":"prompt","requiresInput":false,"aliases":[],"insert":"/plan ","availability":"runs","note":null,"action":null},
     {"name":"usage","description":"Display session usage metrics and statistics","kind":"builtin","source":"Copilot","inputHint":null,"requiresInput":false,"aliases":[],"insert":"/usage ","availability":"runs","note":null,"action":null},
     {"name":"model","description":"Select the AI model for this session","kind":"builtin","source":"Copilot","inputHint":"model","requiresInput":false,"aliases":[],"insert":"/model ","availability":"cantrip","note":"Opens this tab's model settings.","action":"modelSettings"},
     {"name":"allow-all","description":"Enable all permissions","kind":"builtin","source":"Copilot","inputHint":"[on|off|show]","requiresInput":false,"aliases":["yolo"],"insert":"/allow-all ","availability":"unavailable","note":"Cantrip's approval settings decide what Copilot may do in this tab.","action":null},
     {"name":"fixture-skill","description":"Fixture project skill for tests","kind":"skill","source":"Project","inputHint":"instructions for the skill","requiresInput":false,"aliases":[],"insert":"/fixture-skill ","availability":"runs","note":null,"action":null},
     {"name":"review-helper","description":"Review the current diff","kind":"custom","source":"Personal","inputHint":null,"requiresInput":false,"aliases":[],"insert":"/review-helper ","availability":"runs","note":null,"action":null}
    ]}
    """

    /// `-CantripUITestHardwareKeyboard` treats a hardware keyboard as attached (compact "/" rows
    /// then show their keyboard highlight) on a simulator without one.
    static var attachesHardwareKeyboard: Bool {
        ProcessInfo.processInfo.arguments.contains("-CantripUITestHardwareKeyboard")
    }

    /// `-CantripUITestExpandUnavailableSkills` opens the Duo sidebar's "Can't run here" group.
    static var expandsUnavailableSkills: Bool {
        ProcessInfo.processInfo.arguments.contains("-CantripUITestExpandUnavailableSkills")
    }

    /// `-CantripUITestSlashScrollToEnd` scrolls the "/" list to its last rows once it shows.
    static var scrollsSlashListToEnd: Bool {
        ProcessInfo.processInfo.arguments.contains("-CantripUITestSlashScrollToEnd")
    }

    /// `-CantripUITestChooseSlashCommand usage` chooses that row through the same action as a tap
    /// once the "/" list (or, without composer text, the chat's command list) has it, for
    /// end-to-end checks where UI automation can't reach the app.
    static var slashCommandToChoose: String? {
        UserDefaults.standard.string(forKey: "CantripUITestChooseSlashCommand")
    }

    /// `-CantripUITestComposerText "/pl"` types that text into the composer and focuses it once a
    /// session is ready, for screenshots of the "/" suggestions without driving the keyboard.
    static var composerText: String? { UserDefaults.standard.string(forKey: "CantripUITestComposerText") }

    @MainActor
    static func composerTextWhenReady(_ isReady: () -> Bool) async -> String? {
        guard let text = composerText else { return nil }
        for _ in 0..<200 where !isReady() {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard isReady() else { return nil }
        // Let the conversation settle so the focused composer isn't recreated under the text.
        try? await Task.sleep(for: .seconds(1))
        return text
    }

    /// `-CantripUITestRemoteURL http://127.0.0.1:<port> -CantripUITestRemoteToken <token>` pairs
    /// with a local fixture host (saved like a server added in Settings), so UI tests can drive real
    /// Remote and Home flows on the simulator. `-CantripUITestRemoteDirect <host:port>` also saves a
    /// direct address (pass an empty URL to reach the host only through its TLS-PSK listener). `-CantripUITestLane home` opens Cantrip Home, and
    /// `-CantripUITestNotifyHomeRun <session> -CantripUITestNotifyAfter <seconds>` taps a Home
    /// background-run input push through the same handler as a real notification.
    @MainActor
    static func pairRemoteIfRequested(_ remote: CantripRemoteModel, env: HermesEnv) async {
        let defaults = UserDefaults.standard
        guard let url = defaults.string(forKey: "CantripUITestRemoteURL"),
              let token = defaults.string(forKey: "CantripUITestRemoteToken") else { return }
        let direct = defaults.string(forKey: "CantripUITestRemoteDirect")
        func trimmed(_ value: String) -> String { value.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        func saved() -> SavedServer? {
            remote.servers.servers.first {
                trimmed($0.url) == trimmed(url) && $0.directAddress == direct
                    && (try? remote.servers.credential(for: $0)) == token
            }
        }
        if saved() == nil {
            try? remote.addServer(ServerDraft(name: direct == nil ? "UI test host" : "Work laptop", url: url,
                                              credential: token, tailscaleOnly: !url.isEmpty,
                                              directAddress: direct ?? ""))
        }
        guard let server = saved() else { return }
        do { try await remote.selectServer(server) } catch { return }
        if defaults.string(forKey: "CantripUITestLane") == "home" {
            env.select(.home)
            await remote.selectHome()
        } else {
            env.select(.cantrip)
            for _ in 0..<50 where remote.sessions.isEmpty {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if remote.selectedSession == nil, let first = remote.sessions.first {
                await remote.selectSession(first.id)
            }
        }
        // `-CantripUITestNotifyTab <session> -CantripUITestNotifyAfter <seconds>` taps a tab's
        // completion push, which opens the tab inside Cantrip Home.
        if let sessionID = defaults.string(forKey: "CantripUITestNotifyTab"), let serverID = remote.selectedServerID {
            try? await Task.sleep(for: .seconds(defaults.double(forKey: "CantripUITestNotifyAfter")))
            CantripNotifications.shared.simulateTapForUITest([
                "cantrip": [
                    "eventID": UUID().uuidString, "serverID": serverID.uuidString, "sessionID": sessionID,
                    "fingerprint": CantripRemoteModel.notificationFingerprintForUITest(token), "kind": "completion",
                ],
            ])
        }
        if let sessionID = defaults.string(forKey: "CantripUITestNotifyHomeRun"), let serverID = remote.selectedServerID {
            try? await Task.sleep(for: .seconds(defaults.double(forKey: "CantripUITestNotifyAfter")))
            CantripNotifications.shared.simulateTapForUITest([
                "cantrip": [
                    "eventID": UUID().uuidString, "serverID": serverID.uuidString, "sessionID": sessionID,
                    "fingerprint": CantripRemoteModel.notificationFingerprintForUITest(token), "kind": "input", "home": "run",
                ],
            ])
        }
    }
}

#if os(iOS)
struct CantripImageViewerFixtureView: View {
    @State private var source = CantripViewerSource()
    private let image: UIImage = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 1000), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1600, height: 1000))
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 400, y: 250, width: 800, height: 500))
        }
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Viewer fixture").font(.largeTitle.bold())
            Button {
                CantripImageViewerPresenter.present(
                    title: "Fixture image", imageLabel: "Fixture image", placeholder: image,
                    sourceFrame: source.frame, loadID: "fixture", load: { [image] in image }
                )
            } label: {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 180, height: 135)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .cantripViewerSource(source)
            }
            .accessibilityLabel("Open image")
            .accessibilityIdentifier("fixture.openImage")
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
#endif
