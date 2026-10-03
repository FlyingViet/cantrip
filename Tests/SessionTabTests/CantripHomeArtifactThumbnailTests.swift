import AVFoundation
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension SessionTabTests {
    /// Artifacts-grid thumbnails: bounded JPEGs for images, poster frames for videos, cached by
    /// file revision, and the remote-preview file guards for everything they read.
    static func testCantripHomeArtifactThumbnails() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("cantrip-thumbnail-tests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        let root = base.appendingPathComponent("artifacts", isDirectory: true)
        let cache = base.appendingPathComponent("thumbnails", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("reports"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let thumbnails = CantripHomeArtifactThumbnails(artifactRoot: root, cacheRoot: cache, maximumSourceBytes: 4 << 20)
        func artifact(_ path: String, kind: String = "image", mime: String = "image/png") -> CantripHomeArtifact {
            CantripHomeArtifact(title: path, relativePath: path, kind: kind, mimeType: mime, size: 1, createdAt: Date())
        }
        func rejects(_ item: CantripHomeArtifact, as expected: CantripHomeArtifactThumbnails.Failure,
                     _ message: String) async {
            do {
                _ = try await thumbnails.thumbnail(for: item)
                preconditionFailure(message)
            } catch let failure as CantripHomeArtifactThumbnails.Failure {
                precondition(failure == expected, "\(message): \(failure)")
            } catch {
                preconditionFailure("\(message): unexpected \(error)")
            }
        }
        func jpegInfo(_ data: Data) -> (String?, Int, Int, CGImage) {
            let source = CGImageSourceCreateWithData(data as CFData, nil)!
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
            return (CGImageSourceGetType(source) as String?, properties[kCGImagePropertyPixelWidth] as! Int,
                    properties[kCGImagePropertyPixelHeight] as! Int, CGImageSourceCreateImageAtIndex(source, 0, nil)!)
        }

        // Images: a downscaled JPEG, cached until the file changes.
        try thumbnailTestPNG(width: 2400, height: 1200).write(to: root.appendingPathComponent("reports/wide.png"))
        let wide = artifact("reports/wide.png")
        let first = try await thumbnails.thumbnail(for: wide)
        let firstInfo = jpegInfo(first.jpeg)
        precondition(firstInfo.0 == UTType.jpeg.identifier && firstInfo.1 == 600 && firstInfo.2 == 300
                     && first.width == 600 && first.height == 300 && first.durationSeconds == nil
                     && first.jpeg.count <= CantripHomeArtifactThumbnails.maximumJPEGBytes,
                     "nested image artifacts get a bounded JPEG thumbnail: \(first.width)x\(first.height)")
        let cached = try await thumbnails.thumbnail(for: wide)
        let generatedOnce = await thumbnails.generatedCount
        precondition(cached == first && generatedOnce == 1, "an unchanged file is served from the cache")
        let cacheFile = cache.appendingPathComponent("\(wide.id.uuidString).json")
        let fileMode = try FileManager.default.attributesOfItem(atPath: cacheFile.path)[.posixPermissions] as? Int
        let directoryMode = try FileManager.default.attributesOfItem(atPath: cache.path)[.posixPermissions] as? Int
        precondition(fileMode == 0o600 && directoryMode == 0o700, "cached thumbnails are owner-only")
        try await Task.sleep(for: .milliseconds(20))
        try thumbnailTestPNG(width: 300, height: 900).write(to: root.appendingPathComponent("reports/wide.png"))
        let changed = try await thumbnails.thumbnail(for: wide)
        let generatedTwice = await thumbnails.generatedCount
        precondition(changed.width == 200 && changed.height == 600 && generatedTwice == 2,
                     "editing the file regenerates its thumbnail")
        await thumbnails.remove(wide.id)
        precondition(!FileManager.default.fileExists(atPath: cacheFile.path), "deleting an artifact drops its thumbnail")

        // Videos: a poster frame about one second in (past a black lead-in) plus the duration.
        try await thumbnailTestVideo(to: root.appendingPathComponent("clip.mov"), seconds: 3)
        let clip = try await thumbnails.thumbnail(for: artifact("clip.mov", kind: "video", mime: "video/quicktime"))
        let clipInfo = jpegInfo(clip.jpeg)
        precondition(abs((clip.durationSeconds ?? 0) - 3) < 0.25, "videos report their duration: \(String(describing: clip.durationSeconds))")
        precondition(clipInfo.0 == UTType.jpeg.identifier && clip.width == 160 && clip.height == 96,
                     "the poster keeps the video's size under the bound: \(clip.width)x\(clip.height)")
        let center = thumbnailTestPixel(clipInfo.3)
        precondition(center.red > 180 && center.green > 80 && center.blue < 90,
                     "the poster comes from ~1s in, not the black first frame: \(center)")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: cache.path).filter { $0.hasPrefix("source-") }
        precondition(leftovers.isEmpty, "the private decode copy is removed")
        try await thumbnailTestVideo(to: root.appendingPathComponent("blink.mp4"), seconds: 0.6)
        let blink = try await thumbnails.thumbnail(for: artifact("blink.mp4", kind: "video", mime: "video/mp4"))
        precondition(abs((blink.durationSeconds ?? 0) - 0.6) < 0.2, "very short clips still get a poster")

        // Only images and videos have thumbnails.
        try Data("# Notes".utf8).write(to: root.appendingPathComponent("notes.md"))
        await rejects(artifact("notes.md", kind: "document", mime: "text/markdown"), as: .unsupported,
                      "documents keep their type icon")
        await rejects(artifact("song.m4a", kind: "audio", mime: "audio/mp4"), as: .unsupported,
                      "audio keeps its type icon")

        // The same file guards as remote previews.
        let outsideImage = outside.appendingPathComponent("secret.png")
        try thumbnailTestPNG(width: 40, height: 40).write(to: outsideImage)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.png"), withDestinationURL: outsideImage)
        await rejects(artifact("link.png"), as: .unavailable, "symlinked files are refused")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: outside)
        await rejects(artifact("linked/secret.png"), as: .unavailable, "symlinked folders are refused")
        try FileManager.default.linkItem(at: outsideImage, to: root.appendingPathComponent("hard.png"))
        await rejects(artifact("hard.png"), as: .unavailable, "hard links are refused")
        for path in ["../outside/secret.png", outsideImage.path, "reports//wide.png", "./reports/wide.png", "reports/../reports/wide.png", ""] {
            await rejects(artifact(path), as: .unavailable, "paths must stay inside the artifact folder: \(path)")
        }
        try Data(repeating: 1, count: (4 << 20) + 1).write(to: root.appendingPathComponent("huge.png"))
        await rejects(artifact("huge.png"), as: .unavailable, "oversized files are refused before decoding")
        try thumbnailTestPNG(width: 16_385, height: 1).write(to: root.appendingPathComponent("wide-bomb.png"))
        await rejects(artifact("wide-bomb.png"), as: .unavailable, "pixel limits apply")
        try Data("not an image".utf8).write(to: root.appendingPathComponent("fake.png"))
        await rejects(artifact("fake.png"), as: .unavailable, "non-images are refused")
        try Data("not a movie".utf8).write(to: root.appendingPathComponent("fake.mov"))
        await rejects(artifact("fake.mov", kind: "video", mime: "video/quicktime"), as: .unavailable,
                      "unreadable videos fail instead of hanging")
        await rejects(artifact("missing.png"), as: .unavailable, "missing files have no thumbnail")
        print("Home artifact thumbnails: images, video posters, cache, and file guards passed")
    }

    static func thumbnailTestPNG(width: Int, height: Int) throws -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// 160x96 H.264 at 10 fps: black for the first half second, then orange.
    static func thumbnailTestVideo(to url: URL, seconds: Double) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: url.pathExtension == "mp4" ? .mp4 : .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 96
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 96
        ])
        writer.add(input)
        precondition(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let frames = Int((seconds * 10).rounded())
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 160, 96, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixels = buffer!
            CVPixelBufferLockBaseAddress(pixels, [])
            let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(pixels)
            let lit = frame >= 5 && seconds > 1
            for y in 0..<96 {
                for x in 0..<160 {
                    let pixel = base + y * row + x * 4
                    pixel[0] = lit ? 0x20 : 0     // blue
                    pixel[1] = lit ? 0x8C : 0     // green
                    pixel[2] = lit ? 0xF0 : 0     // red
                    pixel[3] = 0xFF
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            precondition(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frames), timescale: 10))
        await writer.finishWriting()
        precondition(writer.status == .completed, "test video: \(String(describing: writer.error))")
    }

    static func thumbnailTestPixel(_ image: CGImage) -> (red: Int, green: Int, blue: Int) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }
}
