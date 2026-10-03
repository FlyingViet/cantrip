import ImageIO
import MarkdownUI
import SwiftUI
import UIKit

enum ChatImageDecoder {
    static func decode(_ data: Data, maximumDimension: Int,
                       maximumBytes: Int = ImageAttachmentProcessor.maximumImageBytes) throws -> UIImage {
        guard !data.isEmpty, data.count <= maximumBytes,
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

/// Markdown links to a Mac image open the full-size viewer instead of a dead file link.
enum ChatPreviewLink {
    enum Action: Equatable {
        case preview(ChatMessageImage)
        case discard
        case inherited
    }

    static func action(for url: URL, images: [ChatMessageImage]) -> Action {
        if let source = ChatMessageImage.preview(for: url, images: images) { return .preview(source) }
        // Unknown preview IDs and Mac file paths from older hosts cannot open on this device.
        return url.scheme == "cantrip-preview" || url.isFileURL ? .discard : .inherited
    }
}

struct ChatAssistantText: View {
    let text: String
    let images: [ChatMessageImage]
    @ObservedObject var remote: CantripRemoteModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        Markdown(text)
            .markdownImageProvider(ChatPreviewImageProvider(images: images, remote: remote))
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                switch ChatPreviewLink.action(for: url, images: images) {
                case .preview(let source):
                    ChatImageViewer.present(source, remote: remote, index: 0)
                    return .handled
                case .discard:
                    return .discarded
                case .inherited:
                    openURL(url)
                    return .handled
                }
            })
    }
}

private struct ChatPreviewImageProvider: ImageProvider {
    let images: [ChatMessageImage]
    let remote: CantripRemoteModel

    @ViewBuilder func makeImage(url: URL?) -> some View {
        if let source = ChatMessageImage.preview(for: url, images: images) {
            ChatGeneratedImagePreview(source: source, remote: remote)
        } else if url?.scheme == "https" || url?.scheme == "http" {
            DefaultImageProvider().makeImage(url: url)
        } else {
            Label("Preview unavailable. Generated images require updated apps and a supported image in Cantrip's output folder.",
                  systemImage: "photo.badge.exclamationmark")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

struct ChatGeneratedImagePreview: View {
    let source: ChatMessageImage
    @ObservedObject var remote: CantripRemoteModel
    @State private var image: UIImage?
    @State private var errorMessage: String?
    @State private var retry = 0
    @State private var viewerSource = CantripViewerSource()

    private var label: String {
        if let alt = source.altText, !alt.isEmpty { return alt }
        return "Generated image"
    }

    var body: some View {
        Button {
            if let image {
                ChatImageViewer.present(source, remote: remote, index: 0,
                                        placeholder: image, sourceFrame: viewerSource.frame)
            } else if errorMessage != nil { retry += 1 }
        } label: {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 600, maxHeight: 360, alignment: .leading)
                        .cantripViewerSource(viewerSource)
                } else if let errorMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Preview unavailable", systemImage: "photo.badge.exclamationmark")
                        Text(errorMessage).font(.callout)
                        Text("Tap to retry").font(.callout.weight(.semibold))
                    }
                    .padding()
                    .frame(maxWidth: 600, minHeight: 120, alignment: .leading)
                } else {
                    ProgressView("Loading preview...")
                        .frame(maxWidth: 600, minHeight: 160)
                }
            }
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(errorMessage ?? (image == nil ? "Loading" : ""))
        .accessibilityHint(errorMessage == nil ? "View full image. Pinch to zoom." : "Double-tap to retry loading")
        .accessibilityIdentifier("chat.generatedPreview")
        .task(id: "\(remote.usageIdentity)/\(source.sessionID ?? "")/\(source.id)/\(retry)") {
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
    @State private var retry = 0
    @State private var viewerSource = CantripViewerSource()

    var body: some View {
        Button {
            if let image {
                ChatImageViewer.present(source, remote: remote, index: index,
                                        placeholder: image, sourceFrame: viewerSource.frame)
            } else if errorMessage != nil { retry += 1 }
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
            .cantripViewerSource(viewerSource)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Attached image \(index + 1)")
        .accessibilityValue(errorMessage ?? (image == nil ? "Loading" : ""))
        .accessibilityHint(errorMessage == nil ? "View full image" : "Double-tap to retry loading")
        .task(id: "\(remote.usageIdentity)/\(source.sessionID ?? "")/\(source.id)/\(retry)") {
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

/// A chat image (upload or Mac preview) in the shared full-screen viewer.
struct ChatImageViewer: View {
    let source: ChatMessageImage
    @ObservedObject var remote: CantripRemoteModel
    let index: Int
    var placeholder: UIImage?
    var sourceFrame: CGRect?
    var onDismiss: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    static func title(_ source: ChatMessageImage, index: Int) -> String {
        ChatMessageImage.validPreviewID(source.id) ? "Preview" : "Image \(index + 1)"
    }

    var body: some View {
        CantripImageViewer(
            title: Self.title(source, index: index),
            imageLabel: source.altText ?? "Attached image \(index + 1)",
            placeholder: placeholder, sourceFrame: sourceFrame,
            loadID: "\(remote.usageIdentity)/\(source.sessionID ?? "")/\(source.id)",
            load: { [source, remote] in try await ChatImageDecoder.load(source, remote: remote, thumbnail: false) },
            onDismiss: onDismiss ?? { dismiss() }
        )
    }

    @MainActor
    static func present(_ source: ChatMessageImage, remote: CantripRemoteModel, index: Int,
                        placeholder: UIImage? = nil, sourceFrame: CGRect? = nil) {
        CantripImageViewerPresenter.present(
            title: title(source, index: index),
            imageLabel: source.altText ?? "Attached image \(index + 1)",
            placeholder: placeholder, sourceFrame: sourceFrame,
            loadID: "\(remote.usageIdentity)/\(source.sessionID ?? "")/\(source.id)",
            load: { try await ChatImageDecoder.load(source, remote: remote, thumbnail: false) }
        )
    }
}

final class ChatImageScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var fittedSize: CGSize = .zero
    /// VoiceOver's two-finger scrub closes the viewer.
    var onEscape: (() -> Bool)?

    var image: UIImage? { imageView.image }

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

    override func accessibilityPerformEscape() -> Bool { onEscape?() ?? false }

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
