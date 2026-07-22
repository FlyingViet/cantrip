import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Captures the main display to a JPEG (downscaled to keep token cost sane)
/// so CLI backends can view it with their file/image tools.
/// Requires the one-time Screen Recording grant in System Settings.
struct DisplayCapture {
    let path: String
    let displayID: CGDirectDisplayID
    let isMain: Bool
    let index: Int          // 1-based, main display first
    let width: Int
    let height: Int
}

final class ScreenCapture {
    static let shared = ScreenCapture()
    /// One capture per active display, main first.
    private(set) var lastCaptures: [DisplayCapture] = []
    var lastCapturePath: String? { lastCaptures.first?.path }

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

    /// Capture ALL active displays (called right before the panel appears,
    /// so the shots show what the user was actually working on). Uses
    /// ScreenCaptureKit — the CGDisplay capture APIs are deprecated on
    /// modern macOS.
    func captureNow() {
        guard AppSettings.shared.attachScreen else { return }
        guard hasAccess else {
            Log.write("screen: no access — enable in System Settings → Privacy → Screen Recording, then relaunch")
            return
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.captureAllDisplays()
        }
    }

    private func captureAllDisplays() async {
        do {
            let content = try await SCShareableContent
                .excludingDesktopWindows(false, onScreenWindowsOnly: true)
            // Main display first, so "display 1" is always the primary.
            let ordered = content.displays.sorted {
                (CGDisplayIsMain($0.displayID) != 0 ? 0 : 1)
                    < (CGDisplayIsMain($1.displayID) != 0 ? 0 : 1)
            }
            guard !ordered.isEmpty else { return }

            pruneOldCaptures()
            let stamp = Int(Date().timeIntervalSince1970)
            var captures: [DisplayCapture] = []
            for (i, display) in ordered.enumerated() {
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                let scale = min(1.0, 1680.0 / Double(max(display.width, 1)))
                config.width = max(1, Int(Double(display.width) * scale))
                config.height = max(1, Int(Double(display.height) * scale))
                config.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: config)
                guard let jpeg = Self.scaledJPEG(image) else { continue }
                let path = dir.appendingPathComponent("screen-\(stamp)-d\(i + 1).jpg")
                try jpeg.write(to: path)
                captures.append(DisplayCapture(
                    path: path.path, displayID: display.displayID,
                    isMain: CGDisplayIsMain(display.displayID) != 0, index: i + 1,
                    width: image.width, height: image.height))
            }
            let finished = captures
            await MainActor.run { self.lastCaptures = finished }
            Log.write("screen: captured \(finished.count) display(s) via ScreenCaptureKit")
        } catch {
            Log.write("screen: capture failed: \(error.localizedDescription)")
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
