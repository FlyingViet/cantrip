import AppKit
import CoreGraphics

/// Captures the main display to a JPEG (downscaled to keep token cost sane)
/// so CLI backends can view it with their file/image tools.
/// Requires the one-time Screen Recording grant in System Settings.
final class ScreenCapture {
    static let shared = ScreenCapture()
    private(set) var lastCapturePath: String?

    private let dir: URL = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/Cantrip")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    var hasAccess: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system Screen Recording prompt if not yet granted.
    /// (macOS requires enabling in System Settings and relaunching the app.)
    func requestAccess() {
        if !hasAccess {
            Log.write("screen: requesting access")
            CGRequestScreenCaptureAccess()
        }
    }

    /// Capture now (called right before the panel appears, so the shot
    /// shows what the user was actually working on). No-op unless enabled.
    func captureNow() {
        guard AppSettings.shared.attachScreen else { return }
        guard hasAccess else {
            Log.write("screen: no access — enable in System Settings → Privacy → Screen Recording, then relaunch")
            return
        }
        guard let image = CGDisplayCreateImage(CGMainDisplayID()),
              let jpeg = Self.scaledJPEG(image) else {
            Log.write("screen: capture failed")
            return
        }
        pruneOldCaptures()
        let path = dir.appendingPathComponent("screen-\(Int(Date().timeIntervalSince1970)).jpg")
        do {
            try jpeg.write(to: path)
            lastCapturePath = path.path
            Log.write("screen: captured \(path.lastPathComponent) (\(jpeg.count / 1024) KB)")
        } catch {
            Log.write("screen: write failed: \(error.localizedDescription)")
        }
    }

    private static func scaledJPEG(_ cg: CGImage, maxWidth: CGFloat = 1680,
                                   quality: CGFloat = 0.7) -> Data? {
        let scale = min(1, maxWidth / CGFloat(cg.width))
        let w = Int(CGFloat(cg.width) * scale)
        let h = Int(CGFloat(cg.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: out)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    private func pruneOldCaptures(keep: Int = 10) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey]))?
            .filter { $0.lastPathComponent.hasPrefix("screen-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } ?? []
        for file in files.dropFirst(keep) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
