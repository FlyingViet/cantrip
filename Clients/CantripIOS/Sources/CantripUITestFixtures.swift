#if DEBUG
import SwiftUI
import UIKit

/// Debug-only screens that UI tests launch directly (`-CantripUITestImageViewer`), so real
/// touches can exercise the image viewer without a paired Mac. Never compiled into Release.
enum CantripUITestFixtures {
    static var showsImageViewer: Bool {
        ProcessInfo.processInfo.arguments.contains("-CantripUITestImageViewer")
    }

    /// `-CantripUITestRemoteURL http://127.0.0.1:<port> -CantripUITestRemoteToken <token>` pairs
    /// with a local fixture host, so UI tests can scroll real paged history on the simulator.
    @MainActor
    static func pairRemoteIfRequested(_ remote: CantripRemoteModel, env: HermesEnv) async {
        let defaults = UserDefaults.standard
        guard let url = defaults.string(forKey: "CantripUITestRemoteURL"),
              let token = defaults.string(forKey: "CantripUITestRemoteToken") else { return }
        guard await remote.configure(url: url, pairingToken: token, tailscaleOnly: true) else { return }
        env.select(.cantrip)
        for _ in 0..<50 where remote.sessions.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if remote.selectedSession == nil, let first = remote.sessions.first {
            await remote.selectSession(first.id)
        }
    }
}

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
