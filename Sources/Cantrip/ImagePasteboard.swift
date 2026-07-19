import AppKit
import UniformTypeIdentifiers

/// Pulls an image off the general pasteboard and returns a file path
/// the CLI backends can view. Copied image *files* are used in place;
/// raw image data (e.g. a screenshot) is saved to the cache folder.
enum ImagePasteboard {
    static func capture() -> String? {
        let pb = NSPasteboard.general

        // Copied file(s) that are images → use the file directly.
        if let urls = pb.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true,
                      .urlReadingContentsConformToTypes: [UTType.image.identifier]]) as? [URL],
           let url = urls.first {
            return url.path
        }

        // Raw image data — but only when there's no text, so normal
        // text pastes (which sometimes carry an image too) aren't hijacked.
        guard pb.string(forType: .string) == nil,
              let image = NSImage(pasteboard: pb),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }

        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/Cantrip")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("pasted-\(Int(Date().timeIntervalSince1970 * 1000)).png")
        do {
            try png.write(to: url)
            Log.write("paste: saved image \(url.lastPathComponent) (\(png.count / 1024) KB)")
            return url.path
        } catch {
            Log.write("paste: save failed: \(error.localizedDescription)")
            return nil
        }
    }
}
