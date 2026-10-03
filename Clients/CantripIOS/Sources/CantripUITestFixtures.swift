#if DEBUG
import SwiftUI
import UIKit

/// Debug-only screens that UI tests launch directly (`-CantripUITestImageViewer`), so real
/// touches can exercise the image viewer without a paired Mac. Never compiled into Release.
enum CantripUITestFixtures {
    static var showsImageViewer: Bool {
        ProcessInfo.processInfo.arguments.contains("-CantripUITestImageViewer")
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
