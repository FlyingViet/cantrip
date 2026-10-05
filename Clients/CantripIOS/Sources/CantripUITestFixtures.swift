#if DEBUG
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Debug-only screens that UI tests launch directly (`-CantripUITestImageViewer`), so real
/// touches can exercise the image viewer without a paired Mac. Never compiled into Release.
enum CantripUITestFixtures {
    static var showsImageViewer: Bool {
        ProcessInfo.processInfo.arguments.contains("-CantripUITestImageViewer")
    }

    static var pairsWithFixtureHost: Bool {
        ProcessInfo.processInfo.arguments.contains("-CantripUITestRemoteURL")
    }

    /// Face ID can't be satisfied from a UI test on the simulator; only fixture-host runs skip it.
    static let authorizeSensitiveAction: (String) async throws -> Void = { reason in
        if pairsWithFixtureHost { return }
        try await CantripBiometrics.authorize(reason)
    }

    /// `-CantripUITestRemoteURL http://127.0.0.1:<port> -CantripUITestRemoteToken <token>` pairs
    /// with a local fixture host (saved like a server added in Settings), so UI tests can drive real
    /// Remote and Home flows on the simulator. `-CantripUITestLane home` opens Cantrip Home, and
    /// `-CantripUITestNotifyHomeRun <session> -CantripUITestNotifyAfter <seconds>` taps a Home
    /// background-run input push through the same handler as a real notification.
    @MainActor
    static func pairRemoteIfRequested(_ remote: CantripRemoteModel, env: HermesEnv) async {
        let defaults = UserDefaults.standard
        guard let url = defaults.string(forKey: "CantripUITestRemoteURL"),
              let token = defaults.string(forKey: "CantripUITestRemoteToken") else { return }
        func trimmed(_ value: String) -> String { value.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        func saved() -> SavedServer? {
            remote.servers.servers.first {
                trimmed($0.url) == trimmed(url) && (try? remote.servers.credential(for: $0)) == token
            }
        }
        if saved() == nil {
            try? remote.addServer(ServerDraft(name: "UI test host", url: url, credential: token, tailscaleOnly: true))
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
