import ImageIO
import SwiftUI
import UIKit

enum ChatImageDecoder {
    static func decode(_ data: Data, maximumDimension: Int) throws -> UIImage {
        guard !data.isEmpty, data.count <= ImageAttachmentProcessor.maximumImageBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { throw ImageAttachmentError.invalidImage }
        return UIImage(cgImage: image)
    }

    @MainActor
    static func load(
        _ source: ChatMessageImage, remote: CantripRemoteModel, thumbnail: Bool
    ) async throws -> UIImage {
        let identity = remote.usageIdentity
        let data: Data
        if let local = source.data {
            data = local
        } else if let sessionID = source.sessionID {
            return try await remote.image(
                sessionID: sessionID, imageID: source.id, thumbnail: thumbnail
            )
        } else {
            throw ImageAttachmentError.invalidImage
        }
        let image = try await Task.detached(priority: .userInitiated) {
            try decode(data, maximumDimension: thumbnail ? 320 : ImageAttachmentProcessor.maximumDimension)
        }.value
        try Task.checkCancellation()
        guard identity == remote.usageIdentity else { throw CancellationError() }
        return image
    }
}

struct ChatImageGallery: View {
    let images: [ChatMessageImage]
    @ObservedObject var remote: CantripRemoteModel

    var body: some View {
        if !images.isEmpty {
            // A wrapping grid keeps all four attachments reachable on narrow phones.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88, maximum: 104))], alignment: .leading) {
                ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                    ChatImageThumbnail(source: image, remote: remote, index: index, size: 88)
                }
            }
            .frame(maxWidth: 220, alignment: .leading)
            .id(remote.usageIdentity)
        }
    }
}

struct ChatImageThumbnail: View {
    let source: ChatMessageImage
    @ObservedObject var remote: CantripRemoteModel
    let index: Int
    var size: CGFloat = 104
    @State private var image: UIImage?
    @State private var errorMessage: String?
    @State private var showingImage = false
    @State private var retry = 0

    var body: some View {
        Button {
            if image != nil { showingImage = true }
            else if errorMessage != nil { retry += 1 }
        } label: {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if errorMessage != nil {
                    VStack(spacing: 4) {
                        Image(systemName: "photo.badge.exclamationmark")
                        Text("Retry").font(.caption)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: size, height: size)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Attached image \(index + 1)")
        .accessibilityValue(errorMessage ?? (image == nil ? "Loading" : ""))
        .accessibilityHint(errorMessage == nil ? "View full image" : "Double-tap to retry loading")
        .fullScreenCover(isPresented: $showingImage) {
            ChatImageViewer(source: source, remote: remote, index: index)
        }
        .task(id: "\(remote.usageIdentity)/\(source.id)/\(retry)") {
            image = nil
            errorMessage = nil
            do {
                image = try await ChatImageDecoder.load(source, remote: remote, thumbnail: true)
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct ChatImageViewer: View {
    let source: ChatMessageImage
    @ObservedObject var remote: CantripRemoteModel
    let index: Int
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var errorMessage: String?
    @State private var retry = 0

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    ZoomableChatImage(image: image)
                        .accessibilityLabel("Attached image \(index + 1)")
                } else if let errorMessage {
                    VStack(spacing: 16) {
                        Label("Image unavailable", systemImage: "photo.badge.exclamationmark")
                        Text(errorMessage).font(.callout).multilineTextAlignment(.center)
                        Button("Retry") { retry += 1 }.buttonStyle(.bordered)
                    }
                    .foregroundStyle(.white)
                    .padding()
                } else {
                    ProgressView("Loading image...").tint(.white).foregroundStyle(.white)
                }
            }
            .navigationTitle("Image \(index + 1)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
        }
        .task(id: "\(remote.usageIdentity)/\(source.id)/\(retry)") {
            image = nil
            errorMessage = nil
            do {
                image = try await ChatImageDecoder.load(source, remote: remote, thumbnail: false)
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct ZoomableChatImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> ChatImageScrollView { ChatImageScrollView() }
    func updateUIView(_ view: ChatImageScrollView, context: Context) { view.setImage(image) }
}

final class ChatImageScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var fittedSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        isAccessibilityElement = true
        accessibilityTraits = [.image, .adjustable]
        accessibilityHint = "Pinch or double-tap to zoom. Drag to pan."
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setImage(_ image: UIImage) {
        guard imageView.image !== image else { return }
        imageView.image = image
        fittedSize = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let image = imageView.image, bounds.width > 0, bounds.height > 0 else { return }
        if fittedSize != bounds.size {
            fittedSize = bounds.size
            minimumZoomScale = 1
            maximumZoomScale = max(1, maximumZoomScale)
            zoomScale = 1
            imageView.frame = CGRect(origin: .zero, size: image.size)
            let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
            minimumZoomScale = fit
            maximumZoomScale = max(1, fit * 6)
            zoomScale = fit
        }
        centerImage()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerImage() }

    private func centerImage() {
        imageView.center = CGPoint(
            x: max(contentSize.width, bounds.width) / 2,
            y: max(contentSize.height, bounds.height) / 2
        )
        accessibilityValue = "\(Int(zoomScale / max(minimumZoomScale, 0.001) * 100)) percent"
    }

    override func accessibilityIncrement() {
        setZoomScale(min(maximumZoomScale, zoomScale * 2), animated: true)
    }

    override func accessibilityDecrement() {
        setZoomScale(max(minimumZoomScale, zoomScale / 2), animated: true)
    }

    @objc private func toggleZoom(_ gesture: UITapGestureRecognizer) {
        guard zoomScale <= minimumZoomScale * 1.01 else {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let scale = min(maximumZoomScale, minimumZoomScale * 3)
        let point = gesture.location(in: imageView)
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                        width: size.width, height: size.height), animated: true)
    }
}
