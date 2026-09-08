import Foundation
import ImageIO
import UniformTypeIdentifiers

private var failures = 0
private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) {
    do {
        if try condition() { return }
    } catch {
        fputs("ERROR: \(error)\n", stderr)
    }
    failures += 1
    fputs("FAIL: \(message)\n", stderr)
}

private func expectRejected(_ value: Any, _ message: String) {
    do {
        _ = try RemoteImageAttachments.decode(value)
        expect(false, message)
    } catch is RemoteImageAttachmentError {
        // Expected validation failure.
    } catch {
        expect(false, "\(message): unexpected error \(error)")
    }
}

private func jpeg(width: Int = 16, height: Int = 8) throws -> Data {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
        output, UTType.jpeg.identifier as CFString, 1, nil
    )!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw RemoteImageAttachmentError.invalid("Could not create test image.")
    }
    return output as Data
}

let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("cantrip-image-tests-\(UUID().uuidString)", isDirectory: true)
do {
    let data = try jpeg()
    let payload = ["data": data.base64EncodedString()]
    let decoded = try RemoteImageAttachments.decode([payload])
    expect(decoded.count == 1 && decoded[0].data == data, "decode exact uploaded image")
    expect(try RemoteImageAttachments.decode(nil).isEmpty, "legacy text request has no images")
    expect(try RemoteImageAttachments.decode([]).isEmpty, "empty attachment list is accepted")
    expectRejected([payload, payload, payload, payload, payload], "reject excessive image count")
    expectRejected(["data": data.base64EncodedString()], "reject non-array images")
    expectRejected([["data": "%%%"]], "reject malformed base64")
    expectRejected([["data": Data("not an image".utf8).base64EncodedString()]], "reject non-images")
    expectRejected([["data": ""]], "reject empty images")
    expectRejected([["path": "/etc/passwd"]], "reject client filesystem paths")
    expectRejected([["data": Data(repeating: 0, count: (1 << 20) + 1).base64EncodedString()]],
                   "reject images over 1 MB")
    expectRejected([["data": try jpeg(width: 2049).base64EncodedString()]],
                   "reject excessive pixel dimensions")

    let sessionID = UUID()
    let plain = try RemoteImageAttachments.preparePrompt(
        "Text only", images: [], sessionID: sessionID, root: root
    )
    expect(plain == "Text only", "leave plain prompts unchanged")
    expect(!FileManager.default.fileExists(atPath: root.path), "text does not create files")

    let prompt = try RemoteImageAttachments.preparePrompt(
        "", images: decoded, sessionID: sessionID, root: root
    )
    expect(prompt.hasPrefix("Please look at the attached images."), "allow image-only messages")
    let sessionDirectory = root.appendingPathComponent(sessionID.uuidString)
    let requests = try FileManager.default.contentsOfDirectory(
        at: sessionDirectory, includingPropertiesForKeys: nil
    )
    let imageURL = requests[0].appendingPathComponent("image-1.jpg")
    expect(try Data(contentsOf: imageURL) == data, "keep pixels on disk for queue and crash recovery")
    let promptPath = prompt.components(separatedBy: "(Attached image: ").last?
        .components(separatedBy: " - view this image file;").first ?? ""
    expect(URL(fileURLWithPath: promptPath).resolvingSymlinksInPath()
        == imageURL.resolvingSymlinksInPath(), "agent prompt references the uploaded file")
    let permissions = try FileManager.default.attributesOfItem(atPath: imageURL.path)[.posixPermissions]
        as? NSNumber
    expect(permissions?.intValue == 0o600, "uploaded images are owner-readable only")
    _ = try RemoteImageAttachments.preparePrompt(
        "Second", images: decoded, sessionID: sessionID, root: root
    )
    let secondRequests = try FileManager.default.contentsOfDirectory(
        at: sessionDirectory, includingPropertiesForKeys: nil
    )
    expect(secondRequests.count == 2, "different requests cannot overwrite queued images")
    expect(try Data(contentsOf: imageURL) == data, "earlier queued image remains available")

    let presentation = RemoteImageAttachments.presentation(prompt, sessionID: sessionID, root: root)
    expect(presentation.text == "Please look at the attached images.", "hide the upload marker only")
    expect(presentation.imageIDs == [requests[0].lastPathComponent + "/image-1.jpg"],
           "publish session-scoped IDs, not file paths")
    let imageID = presentation.imageIDs[0]
    expect(try RemoteImageAttachments.read(id: imageID, sessionID: sessionID,
                                          thumbnail: false, root: root) == data,
           "read original uploaded pixels")
    let thumb = try RemoteImageAttachments.read(id: imageID, sessionID: sessionID,
                                               thumbnail: true, root: root)
    expect(CGImageSourceCreateWithData(thumb as CFData, nil) != nil, "thumbnail is a decodable image")
    expect(RemoteImageAttachments.presentation(prompt, sessionID: UUID(), root: root).imageIDs.isEmpty,
           "a copied marker from a different session is not exposed")
    let arbitrary = "(Attached image: /etc/passwd - view this image file; it is part of my request.)"
    expect(RemoteImageAttachments.presentation(arbitrary, sessionID: sessionID, root: root).text == arbitrary,
           "ordinary file paths remain untouched")
    for id in ["../image-1.jpg", imageID + "/extra", imageID.replacingOccurrences(of: "image-1", with: "image-5"),
               imageID.replacingOccurrences(of: "/", with: "/../")] {
        expect(!RemoteImageAttachments.validID(id), "reject path traversal and invalid image IDs")
    }
    let sourcePrompt = "Look at this\n\n" + prompt
    expect(RemoteImageAttachments.presentation(sourcePrompt, sessionID: sessionID, root: root).text
        == "Look at this\n\nPlease look at the attached images.", "preserve typed prompt text")
    let largePrompt = try RemoteImageAttachments.preparePrompt(
        "Large", images: [RemoteImageUpload(data: jpeg(width: 1200, height: 600))],
        sessionID: sessionID, root: root
    )
    let largeID = RemoteImageAttachments.presentation(largePrompt, sessionID: sessionID, root: root).imageIDs[0]
    let small = try RemoteImageAttachments.read(id: largeID, sessionID: sessionID, thumbnail: true, root: root)
    let smallSource = CGImageSourceCreateWithData(small as CFData, nil)!
    let dimensions = CGImageSourceCopyPropertiesAtIndex(smallSource, 0, nil)! as NSDictionary
    expect(dimensions[kCGImagePropertyPixelWidth] as? Int == 320, "thumbnail dimension is bounded")
    expect(dimensions[kCGImagePropertyPixelHeight] as? Int == 160, "thumbnail preserves aspect ratio")
    try FileManager.default.removeItem(at: imageURL)
    try FileManager.default.createSymbolicLink(at: imageURL, withDestinationURL:
        root.appendingPathComponent(sessionID.uuidString).appendingPathComponent(largeID))
    do {
        _ = try RemoteImageAttachments.read(id: imageID, sessionID: sessionID, thumbnail: false, root: root)
        expect(false, "reject a replaced symlink even when it points to another image")
    } catch is RemoteImageAttachmentError {}

    let fourImages = try JSONSerialization.data(withJSONObject: [
        "text": "", "mode": "queue",
        "images": Array(repeating: ["data": Data(repeating: 0, count: 1 << 20).base64EncodedString()], count: 4)
    ])
    expect(fourImages.count + 1024 < RemoteImageAttachments.maximumRequestBytes,
           "four maximum-sized uploads fit the HTTP request limit")
} catch {
    failures += 1
    fputs("FAIL: \(error)\n", stderr)
}
if FileManager.default.fileExists(atPath: root.path) {
    do { try FileManager.default.removeItem(at: root) }
    catch {
        failures += 1
        fputs("FAIL: cleanup \(error)\n", stderr)
    }
}
if failures > 0 { exit(1) }
print("All remote image attachment tests passed")
