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

private func jpeg(width: Int = 16, height: Int = 8, type: UTType = .jpeg) throws -> Data {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
        output, type.identifier as CFString, 1, nil
    )!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw RemoteImageAttachmentError.invalid("Could not create test image.")
    }
    return output as Data
}

private func expectUnreadable(_ reference: RemoteGeneratedImages.Reference, cache: URL, _ message: String) {
    do {
        _ = try RemoteGeneratedImages.read(reference, sessionID: UUID(), thumbnail: false, root: cache)
        expect(false, message)
    } catch is RemoteImageAttachmentError {
    } catch {
        expect(false, "\(message): unexpected error \(error)")
    }
}

/// Markdown links open previews; session-owned folders allow subfolders, the shared one doesn't.
/// "**Before**\n![..](..)" parses as one paragraph, where clients drop the image. Every
/// rewritten image line becomes its own block; text, code and unpublished images stay as written.
private func checkStandaloneImageBlocks(generatedRoot: URL, screenshot: URL, messageID: UUID) {
    let markdown = "Copilot needs your answer\n\n**Light — before**\n![Before](\(screenshot.path))\n"
        + "![Before, dark](<\(screenshot.path)>)\n**Light — after**\n  ![After](\(screenshot.absoluteString))\n\n"
        + "Ship it?\n![Elsewhere](/tmp/elsewhere.png)\n```\n**Code**\n![Code](\(screenshot.path))\n```"
    let presented = RemoteGeneratedImages.presentation(markdown, messageID: messageID, root: generatedRoot)
    let url = presented.images.first?.markdownURL ?? "missing"
    expect(presented.images.count == 1, "one source, one reference")
    expect(presented.text == "Copilot needs your answer\n\n**Light — before**\n\n![Before](\(url))\n"
        + "![Before, dark](\(url))\n\n**Light — after**\n\n  ![After](\(url))\n\n"
        + "Ship it?\n![Elsewhere](/tmp/elsewhere.png)\n```\n**Code**\n![Code](\(screenshot.path))\n```",
           "separate rewritten images from adjacent text only: \(presented.text)")
    let again = RemoteGeneratedImages.presentation(presented.text, messageID: messageID, root: generatedRoot)
    expect(again.text == presented.text, "already separated images gain no extra lines")
    let crlf = RemoteGeneratedImages.presentation("**A**\r\n![A](\(screenshot.path))\r\nB",
                                                  messageID: messageID, root: generatedRoot)
    expect(crlf.text == "**A**\r\n\n![A](\(url))\r\n\nB", "CRLF text separates too: \(crlf.text.debugDescription)")
}

private func checkLinksAndNesting(generatedRoot: URL, screenshot: URL, cache: URL,
                                  messageID: UUID, sessionID: UUID) throws {
    let imageID = RemoteGeneratedImages.presentation(
        "![Duo](\(screenshot.path))", messageID: messageID, root: generatedRoot
    ).images[0].id
    let linked = RemoteGeneratedImages.presentation(
        "Saved. [Open the full-size preview](\(screenshot.absoluteString)) or `[raw](\(screenshot.path))`.",
        messageID: messageID, root: generatedRoot
    )
    expect(linked.images.map(\.id) == [imageID], "a link to an eligible image becomes a viewer reference")
    expect(linked.text == "Saved. [Open the full-size preview](\(linked.images[0].markdownURL)) or "
        + "`[raw](\(screenshot.path))`.", "rewrite only the link target, never inline code")
    expect(linked.images[0].altText == "Open the full-size preview", "link text labels the viewer")
    let both = RemoteGeneratedImages.presentation(
        "![Header](\(screenshot.path))\n[Full size](<\(screenshot.path)>) and [site](https://example.com)",
        messageID: messageID, root: generatedRoot
    )
    expect(both.images.count == 1 && both.images[0].altText == "Header",
           "an image and a link to the same file share one reference")
    expect(both.text.hasSuffix("[Full size](\(both.images[0].markdownURL)) and [site](https://example.com)"),
           "web links stay untouched")

    // Agent files folder: ~/.copilot/session-state/<id>/files with nested subfolders.
    let state = generatedRoot.deletingLastPathComponent().appendingPathComponent("session-state", isDirectory: true)
    let files = state.appendingPathComponent("\(UUID())/files", isDirectory: true)
    let nested = files.appendingPathComponent("screens/ios", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let nestedImage = nested.appendingPathComponent("header preview.png")
    try jpeg(width: 943, height: 2048, type: .png).write(to: nestedImage)
    let direct = files.appendingPathComponent("direct.jpg")
    try jpeg().write(to: direct)
    let nestedMarkdown = "![Header](<\(nestedImage.path)>)\n[Open](\(nestedImage.absoluteString))\n![Direct](\(direct.path))"
    expect(RemoteGeneratedImages.presentation(nestedMarkdown, messageID: messageID, root: generatedRoot).images.isEmpty,
           "another session's files folder is not an allowed root")
    let owned = RemoteGeneratedImages.presentation(
        nestedMarkdown, messageID: messageID, root: generatedRoot, additionalRoots: [files]
    )
    expect(owned.images.count == 2 && owned.images.allSatisfy { $0.root.path == files.path },
           "own files folder previews nested and direct images")
    let full = try RemoteGeneratedImages.read(owned.images[0], sessionID: sessionID, thumbnail: false, root: cache)
    let size = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithData(full as CFData, nil)!, 0, nil)! as NSDictionary
    expect(size[kCGImagePropertyPixelHeight] as? Int == 2048, "read a nested session image at full size")
    let deep = files.appendingPathComponent((1...9).map { "d\($0)" }.joined(separator: "/"), isDirectory: true)
    try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
    try jpeg(type: .png).write(to: deep.appendingPathComponent("deep.png"))
    let hidden = files.appendingPathComponent(".git", isDirectory: true)
    try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
    try jpeg(type: .png).write(to: hidden.appendingPathComponent("hidden.png"))
    for target in [
        deep.appendingPathComponent("deep.png").path, hidden.appendingPathComponent("hidden.png").path,
        files.path + "/screens/../../../outside.png", files.path + "/screens/%2E%2E/%2E%2E/escape.png",
        files.path + "/./screens/ios/header%20preview.png", files.deletingLastPathComponent().path + "/sibling.png",
        files.path + "-evil/screens/x.png"
    ] {
        let rejected = RemoteGeneratedImages.presentation(
            "![x](\(target))\n[x](\(target))", messageID: messageID, root: generatedRoot, additionalRoots: [files]
        )
        expect(rejected.images.isEmpty, "reject traversal, hidden, too-deep or sibling paths: \(target)")
    }
    let sharedNested = generatedRoot.appendingPathComponent("remote-attachments/\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: sharedNested, withIntermediateDirectories: true)
    try jpeg().write(to: sharedNested.appendingPathComponent("image-1.jpg"))
    expect(RemoteGeneratedImages.presentation(
        "[Upload](\(sharedNested.path)/image-1.jpg)", messageID: messageID, root: generatedRoot,
        additionalRoots: [files]
    ).images.isEmpty, "the shared output folder stays flat, so per-session caches below it stay private")

    // A subfolder swapped for a symlink is refused when read, even after it was validated.
    let outsideDirectory = generatedRoot.deletingLastPathComponent().appendingPathComponent("outside-dir")
    try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
    try jpeg(type: .png).write(to: outsideDirectory.appendingPathComponent("swap.png"))
    let swapped = files.appendingPathComponent("swap", isDirectory: true)
    try FileManager.default.createDirectory(at: swapped, withIntermediateDirectories: true)
    try jpeg(type: .png).write(to: swapped.appendingPathComponent("swap.png"))
    let swappedReference = RemoteGeneratedImages.presentation(
        "![Swap](\(swapped.path)/swap.png)", messageID: messageID, root: generatedRoot, additionalRoots: [files]
    ).images[0]
    try FileManager.default.removeItem(at: swapped)
    try FileManager.default.createSymbolicLink(at: swapped, withDestinationURL: outsideDirectory)
    expectUnreadable(swappedReference, cache: cache, "reject a symlinked subfolder")
    let linkedFiles = state.appendingPathComponent("\(UUID())/files", isDirectory: true)
    try FileManager.default.createDirectory(at: linkedFiles.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: linkedFiles, withDestinationURL: outsideDirectory)
    let linkedRoot = RemoteGeneratedImages.presentation(
        "![Root](\(linkedFiles.path)/swap.png)", messageID: messageID, root: generatedRoot,
        additionalRoots: [linkedFiles]
    ).images
    expect(linkedRoot.count == 1, "the symlinked root path is recognized before reading")
    if let first = linkedRoot.first { expectUnreadable(first, cache: cache, "reject a symlinked files folder") }
}

/// Each session previews only the CLI sessions recorded for it; the backfill never guesses.
private func checkSessionOutputFolders(base: URL) throws {
    let state = base.appendingPathComponent("session-state", isDirectory: true)
    let file = base.appendingPathComponent("folders.json")
    let tab = UUID(), other = UUID(), run = UUID(), log = UUID()
    let cli = UUID().uuidString.lowercased(), second = UUID().uuidString.lowercased()
    var folders = SessionOutputFolders(file: file, copilotStateRoot: state)
    folders.record(cli.uppercased(), for: tab)
    folders.record(cli, for: tab)
    folders.record("../../etc", for: tab)
    folders.record("", for: tab)
    folders.record(second, for: tab)
    expect(folders.roots(for: tab).map(\.path) == [
        state.appendingPathComponent("\(second)/files").path, state.appendingPathComponent("\(cli)/files").path
    ], "record canonical CLI session IDs once, newest first, rejecting unsafe IDs")
    expect(folders.roots(for: other).isEmpty, "another session gets none of them")
    let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
    expect(mode == 0o600, "the registry is owner-only")
    folders = SessionOutputFolders(file: file, copilotStateRoot: state)
    expect(folders.roots(for: tab).count == 2, "records survive a restart")
    for _ in 0..<(SessionOutputFolders.maximumPerSession + 5) { folders.record(UUID().uuidString, for: other) }
    expect(folders.roots(for: other).count == SessionOutputFolders.maximumPerSession, "bound folders per session")
    folders.record(UUID().uuidString, for: run)
    let runRoots = folders.roots(for: run)
    folders.transfer(from: run, to: log)
    expect(folders.roots(for: run).isEmpty && folders.roots(for: log) == runRoots,
           "a retired Home run's folders move to the background log")
    folders.remove(tab)
    expect(SessionOutputFolders(file: file, copilotStateRoot: state).roots(for: tab).isEmpty,
           "deleting a session forgets its folders")

    // Backfill: transcripts reference folders; only prompt evidence assigns them.
    let chats = base.appendingPathComponent("chats", isDirectory: true)
    try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
    func session(_ cli: String, client: String = "Cantrip", prompts: [String]) throws {
        let folder = state.appendingPathComponent(cli, isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("files"), withIntermediateDirectories: true)
        try "id: \(cli)\ncwd: /tmp\nclient_name: \(client)\n".write(
            to: folder.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8)
        var lines = [#"{"type":"session.start","data":{"sessionId":"\#(cli)"}}"#]
        for prompt in prompts {
            // The CLI writes "type" first; the reader relies on that prefix.
            let content = try JSONSerialization.data(withJSONObject: prompt, options: .fragmentsAllowed)
            lines.append(#"{"type":"user.message","data":{"content":"# + String(decoding: content, as: UTF8.self) + "}}")
            lines.append(#"{"type":"assistant.message","data":{"content":"ok"}}"#)
        }
        try lines.joined(separator: "\n").appending("\n").write(
            to: folder.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)
    }
    func transcript(_ id: UUID, _ messages: [(String, String)]) throws {
        let data = try JSONSerialization.data(withJSONObject: messages.map { ["id": UUID().uuidString, "role": $0.0, "text": $0.1] })
        try data.write(to: chats.appendingPathComponent("\(id.uuidString).json"))
    }
    let bass = UUID(), home = UUID(), quiet = UUID(), copied = UUID()
    let owned = UUID().uuidString.lowercased(), homeCLI = UUID().uuidString.lowercased()
    let foreignClient = UUID().uuidString.lowercased(), ambiguous = UUID().uuidString.lowercased()
    let bassAsk = "Can you show me a preview of the Niteharts set times header?"
    let shared = "Please rerun the nightly ingestion check for every festival."
    try session(owned, prompts: ["Context - selected earlier turns\n\(bassAsk)\n(Persistent memory ...)"])
    try session(homeCLI, prompts: ["Context\nSummarize the Home inbox and list every open follow-up."])
    try session(foreignClient, client: "copilot-cli", prompts: ["Context\n\(bassAsk)"])
    try session(ambiguous, prompts: ["Context\n\(shared)"])
    func image(_ cli: String) -> String { "![Preview](file://\(state.path)/\(cli)/files/sub/a.png)" }
    try transcript(bass, [("user", bassAsk), ("assistant", image(owned) + "\n" + image(foreignClient)),
                          ("user", shared), ("assistant", image(ambiguous))])
    // Home quotes the tab's image and another session's folder, but its prompts never reached them.
    try transcript(home, [("user", "Summarize the Home inbox and list every open follow-up?"),
                          ("assistant", image(owned) + "\n" + image(homeCLI))])
    try transcript(copied, [("user", shared), ("assistant", image(ambiguous))])
    try transcript(quiet, [("user", "short"), ("assistant", "No images.")])
    let fresh = base.appendingPathComponent("fresh.json")
    folders = SessionOutputFolders(file: fresh, copilotStateRoot: state)
    folders.backfillIfNeeded(transcripts: chats)
    expect(folders.roots(for: bass) == [state.appendingPathComponent("\(owned)/files")],
           "backfill assigns a folder only to the session whose unique prompts it received")
    expect(folders.roots(for: home).isEmpty, "a session quoting another session's folder gets nothing")
    expect(folders.roots(for: copied).isEmpty, "shared prompt text is not evidence")
    try transcript(home, [("user", "Summarize the Home inbox and list every open follow-up."),
                          ("assistant", image(homeCLI))])
    folders.backfillIfNeeded(transcripts: chats)
    expect(folders.roots(for: home).isEmpty, "the backfill runs only once")
    expect(SessionOutputFolders(file: fresh, copilotStateRoot: state).roots(for: bass).count == 1,
           "backfilled folders persist")
    let rerun = SessionOutputFolders(file: base.appendingPathComponent("again.json"), copilotStateRoot: state)
    rerun.backfillIfNeeded(transcripts: chats)
    expect(rerun.roots(for: home) == [state.appendingPathComponent("\(homeCLI)/files")],
           "exact unique prompt evidence assigns the folder")
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

    let generatedRoot = root.resolvingSymlinksInPath().appendingPathComponent("generated")
    let cache = root.resolvingSymlinksInPath().appendingPathComponent("previews")
    try FileManager.default.createDirectory(at: generatedRoot, withIntermediateDirectories: true)
    let screenshot = generatedRoot.appendingPathComponent("Duo preview.png")
    try jpeg(width: 2400, height: 1200, type: .png).write(to: screenshot)
    let messageID = UUID()
    let markdown = "Before\n\n![Duo landscape](<\(screenshot.path)>)\n\nAfter"
    let preview = RemoteGeneratedImages.presentation(markdown, messageID: messageID, root: generatedRoot)
    expect(preview.images.count == 1, "recognize a standalone PNG block with spaces")
    let reference = preview.images[0]
    expect(reference.altText == "Duo landscape", "retain the accessible preview description")
    expect(RemoteGeneratedImages.validID(reference.id), "generate a bounded opaque preview ID")
    expect(preview.text == "Before\n\n![Duo landscape](\(reference.markdownURL))\n\nAfter",
           "keep preview placement and surrounding Markdown intact")
    expect(RemoteGeneratedImages.presentation(
        "![Duo](\(screenshot.absoluteString))", messageID: messageID, root: generatedRoot
    ).images.first?.id == reference.id, "file URLs and encoded paths resolve to the same reference")
    expect(RemoteGeneratedImages.presentation(
        markdown + "\n" + markdown, messageID: messageID, root: generatedRoot
    ).images.count == 1, "deduplicate repeated references")
    let homeArtifacts = generatedRoot.appendingPathComponent("home/artifacts", isDirectory: true)
    try FileManager.default.createDirectory(at: homeArtifacts, withIntermediateDirectories: true)
    let homeImage = homeArtifacts.appendingPathComponent("tracker.png")
    try jpeg(type: .png).write(to: homeImage)
    let homeMarkdown = "![Tracker](\(homeImage.path))"
    expect(RemoteGeneratedImages.presentation(
        homeMarkdown, messageID: messageID, root: generatedRoot
    ).images.isEmpty, "nested directories remain excluded by default")
    let homePreview = RemoteGeneratedImages.presentation(
        homeMarkdown, messageID: messageID, root: generatedRoot,
        additionalRoots: [homeArtifacts]
    )
    expect(homePreview.images.count == 1, "an explicitly allowed Home artifact directory is previewable")
    expect(
        try !RemoteGeneratedImages.read(
            homePreview.images[0], sessionID: sessionID, thumbnail: true, root: cache
        ).isEmpty,
        "read a validated Home artifact preview"
    )
    for text in [
        "```\n\(markdown)\n```", "~~~md\n\(markdown)\n~~~", "    ![Example](\(screenshot.path))",
        "`![Example](\(screenshot.path))`", "`[Download](\(screenshot.path))`",
        "``a ` [Download](\(screenshot.path)) ``", "\\[Escaped](\(screenshot.path))",
        "```\n[Download](\(screenshot.path))\n```", "[Outside](/etc/secret.png)",
        "![Outside](/etc/secret.png)", "![Outside](\(generatedRoot.path)/../secret.png)",
        "![Upload](\(generatedRoot.path)/remote-attachments/\(sessionID)/image-1.jpg)",
        "![SVG](\(generatedRoot.path)/unsafe.svg)", "![Remote](https://example.com/image.png)",
        "![Partial](\(screenshot.path)"
    ] {
        let ignored = RemoteGeneratedImages.presentation(text, messageID: messageID, root: generatedRoot)
        expect(ignored.images.isEmpty && ignored.text == text, "do not publish unsupported or quoted image paths")
    }
    try checkLinksAndNesting(generatedRoot: generatedRoot, screenshot: screenshot, cache: cache,
                             messageID: messageID, sessionID: sessionID)
    checkStandaloneImageBlocks(generatedRoot: generatedRoot, screenshot: screenshot, messageID: messageID)
    try checkSessionOutputFolders(base: root.resolvingSymlinksInPath().appendingPathComponent("registry"))
    let many = (0..<20).map { "![\($0)](\(generatedRoot.path)/\($0).png)" }.joined(separator: "\n\n")
    expect(RemoteGeneratedImages.presentation(many, messageID: messageID, root: generatedRoot).images.count == 8,
           "bound generated previews per message")
    for id in ["previews/\(messageID)/../file.jpg", "previews/\(messageID)/\(String(repeating: "a", count: 64)).png",
               reference.id + "?path=secret", reference.id + "/extra"] {
        expect(!RemoteGeneratedImages.validID(id), "reject invalid preview route IDs")
    }
    let generated = try RemoteGeneratedImages.read(reference, sessionID: sessionID, thumbnail: false, root: cache)
    let generatedSource = CGImageSourceCreateWithData(generated as CFData, nil)!
    expect(CGImageSourceGetType(generatedSource) as String? == UTType.jpeg.identifier,
           "normalize generated PNGs to safe JPEG delivery")
    let generatedProperties = CGImageSourceCopyPropertiesAtIndex(generatedSource, 0, nil)! as NSDictionary
    expect(generatedProperties[kCGImagePropertyPixelWidth] as? Int == 2400, "retain readable screenshot pixels")
    let generatedThumbnail = try RemoteGeneratedImages.read(reference, sessionID: sessionID, thumbnail: true, root: cache)
    let previewProperties = CGImageSourceCopyPropertiesAtIndex(
        CGImageSourceCreateWithData(generatedThumbnail as CFData, nil)!, 0, nil
    )! as NSDictionary
    expect(previewProperties[kCGImagePropertyPixelWidth] as? Int == 960, "bound inline preview width")
    expect(previewProperties[kCGImagePropertyPixelHeight] as? Int == 480, "do not crop landscape previews")
    try FileManager.default.removeItem(at: screenshot)
    expect(try RemoteGeneratedImages.read(reference, sessionID: sessionID, thumbnail: false, root: cache) == generated,
           "cached preview survives source cleanup and store recreation")
    do {
        _ = try RemoteGeneratedImages.read(reference, sessionID: UUID(), thumbnail: false, root: cache)
        expect(false, "one session cannot reuse another session's cached preview")
    } catch is RemoteImageAttachmentError {}
    let forbidden = generatedRoot.appendingPathComponent("linked.png")
    let outside = root.appendingPathComponent("outside.png")
    try jpeg(type: .png).write(to: outside)
    try FileManager.default.createSymbolicLink(at: forbidden, withDestinationURL: outside)
    let linkReference = RemoteGeneratedImages.presentation(
        "![Link](\(forbidden.path))", messageID: messageID, root: generatedRoot
    ).images[0]
    do {
        _ = try RemoteGeneratedImages.read(linkReference, sessionID: sessionID, thumbnail: false, root: cache)
        expect(false, "reject generated-image symlinks")
    } catch is RemoteImageAttachmentError {}
    try FileManager.default.removeItem(at: forbidden)
    try FileManager.default.linkItem(at: outside, to: forbidden)
    do {
        _ = try RemoteGeneratedImages.read(linkReference, sessionID: sessionID, thumbnail: false, root: cache)
        expect(false, "reject generated-image hard links")
    } catch is RemoteImageAttachmentError {}
    try FileManager.default.removeItem(at: forbidden)
    try Data("not an image".utf8).write(to: forbidden)
    do {
        _ = try RemoteGeneratedImages.read(linkReference, sessionID: sessionID, thumbnail: false, root: cache)
        expect(false, "reject fake PNG files")
    } catch is RemoteImageAttachmentError {}
    try jpeg(width: 32, height: 16, type: .png).prefix(50).write(to: forbidden)
    do {
        _ = try RemoteGeneratedImages.read(linkReference, sessionID: sessionID, thumbnail: false, root: cache)
        expect(false, "reject incomplete image writes instead of caching partial previews")
    } catch is RemoteImageAttachmentError {}
    try Data(repeating: 0, count: RemoteGeneratedImages.maximumSourceBytes + 1).write(to: forbidden)
    do {
        _ = try RemoteGeneratedImages.read(linkReference, sessionID: sessionID, thumbnail: false, root: cache)
        expect(false, "reject oversized generated-image files before decoding")
    } catch is RemoteImageAttachmentError {}
    try jpeg(width: 5000, height: 10, type: .png).write(to: forbidden)
    let resized = try RemoteGeneratedImages.read(linkReference, sessionID: sessionID, thumbnail: false, root: cache)
    let resizedProperties = CGImageSourceCopyPropertiesAtIndex(
        CGImageSourceCreateWithData(resized as CFData, nil)!, 0, nil
    )! as NSDictionary
    expect(resizedProperties[kCGImagePropertyPixelWidth] as? Int == 4096,
           "full-screen generated previews respect the 4096-pixel bound")
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
