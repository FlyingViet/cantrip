import UniformTypeIdentifiers
import XCTest
@testable import Hermes
#if os(macOS)
import AppKit
#endif

final class ComposerPasteTests: XCTestCase {
    private let pdf = UTType.pdf.identifier
    private let png = UTType.png.identifier
    private let text = UTType.utf8PlainText.identifier

    func testTextWinsUnlessFilesWereCopied() {
        XCTAssertTrue(ComposerPaste.attaches([[png]]), "a screenshot attaches")
        XCTAssertTrue(ComposerPaste.attaches([[UTType.quickTimeMovie.identifier]]), "a video attaches")
        XCTAssertTrue(ComposerPaste.attaches([[pdf]]), "a document copied as data attaches")
        XCTAssertTrue(ComposerPaste.attaches([[pdf, UTType.fileURL.identifier, UTType.url.identifier]]))
        XCTAssertTrue(ComposerPaste.attaches([[UTType.fileURL.identifier, text]]),
                      "Finder copies carry the file name as text but still attach")
        XCTAssertFalse(ComposerPaste.attaches([[text]]))
        XCTAssertFalse(ComposerPaste.attaches([[png, text]]), "a copied cell or note with its picture pastes text")
        XCTAssertFalse(ComposerPaste.attaches([[png], [UTType.html.identifier]]), "text in any item wins")
        XCTAssertFalse(ComposerPaste.attaches([[UTType.url.identifier]]), "a web link pastes as text")
        XCTAssertFalse(ComposerPaste.attaches([["com.example.private-shape"]]), "app-private data isn't a document")
        XCTAssertFalse(ComposerPaste.attaches([]))
    }

    func testClassifiesEachItemByItsMostUsefulForm() {
        let image = NSItemProvider()
        image.registerDataRepresentation(forTypeIdentifier: "com.apple.uikit.image", visibility: .all) { _ in nil }
        image.registerDataRepresentation(forTypeIdentifier: png, visibility: .all) { _ in nil }
        let movie = NSItemProvider()
        movie.registerDataRepresentation(forTypeIdentifier: UTType.mpeg4Movie.identifier, visibility: .all) { _ in nil }
        let document = NSItemProvider()
        document.registerDataRepresentation(forTypeIdentifier: pdf, visibility: .all) { _ in nil }

        let private_ = NSItemProvider()
        private_.registerDataRepresentation(forTypeIdentifier: "com.example.private-shape", visibility: .all) { _ in nil }
        let folder = NSItemProvider()
        folder.registerDataRepresentation(forTypeIdentifier: UTType.folder.identifier, visibility: .all) { _ in nil }

        let items = ComposerPaste.classify([image, folder, movie, private_, document])
        XCTAssertEqual(items.map(\.kind), [.image, .video, .file], "folders and private data are left out")
        XCTAssertEqual(items.map(\.type), [.png, .mpeg4Movie, .pdf])
    }

    func testCopiedFilesAttachAsDocumentsUnlessTheyArePlayableOrReadable() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("paste-kinds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func kind(_ name: String) throws -> ComposerPaste.Kind? {
            let file = folder.appendingPathComponent(name)
            try Data("x".utf8).write(to: file)
            let provider = try XCTUnwrap(NSItemProvider(contentsOf: file))
            return ComposerPaste.classify([provider]).first?.kind
        }
        for name in ["main.go", "index.ts", "Makefile", ".env", "notes.txt", "clip.m4v", "Report.pdf"] {
            XCTAssertEqual(try kind(name), .file, name)
        }
        XCTAssertEqual(try kind("clip.mov"), .video)
        XCTAssertEqual(try kind("clip.mp4"), .video)
        XCTAssertEqual(try kind("photo.png"), .image)
        XCTAssertEqual(try kind("photo.heic"), .image)
    }

    func testFileNamesKeepTheirNameAndGainTheTypesExtension() {
        XCTAssertEqual(ComposerPaste.fileName("Report.pdf", type: .pdf), "Report.pdf")
        XCTAssertEqual(ComposerPaste.fileName("IMG_0001.MOV", type: .quickTimeMovie), "IMG_0001.MOV")
        XCTAssertEqual(ComposerPaste.fileName("clip", type: .mpeg4Movie), "clip.mp4")
        XCTAssertEqual(ComposerPaste.fileName("a/b:c.pdf", type: .pdf), "a-b-c.pdf")
        XCTAssertEqual(ComposerPaste.fileName("  ", type: .pdf), "Pasted.pdf")
        XCTAssertEqual(ComposerPaste.fileName("README", type: .plainText, copiedAsFile: true), "README")
        XCTAssertEqual(ComposerPaste.fileName(".env", type: .data, copiedAsFile: true), ".env")
    }

    func testCopiesPastedFilesAndData() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("paste-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        let file = source.appendingPathComponent("Quarterly Report.pdf")
        try Data("%PDF-1.4 test".utf8).write(to: file)
        let folder = ComposerPaste.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let provider = try XCTUnwrap(NSItemProvider(contentsOf: file))
        let item = try XCTUnwrap(ComposerPaste.classify([provider]).first)
        XCTAssertTrue(item.copiedAsFile)
        let copy = try await ComposerPaste.copyFile(item, into: folder)
        XCTAssertEqual(copy.lastPathComponent, "Quarterly Report.pdf")
        XCTAssertEqual(try Data(contentsOf: copy), Data("%PDF-1.4 test".utf8))
        XCTAssertTrue(copy.path.hasPrefix(folder.path))

        let goFile = source.appendingPathComponent("main.go")
        try Data("package main".utf8).write(to: goFile)
        let code = try XCTUnwrap(ComposerPaste.classify([try XCTUnwrap(NSItemProvider(contentsOf: goFile))]).first)
        let codeCopy = try await ComposerPaste.copyFile(code, into: folder)
        XCTAssertEqual(codeCopy.lastPathComponent, "main.go")
        XCTAssertEqual(try Data(contentsOf: codeCopy), Data("package main".utf8))

        let bytes = Data([1, 2, 3])
        let data = NSItemProvider(item: bytes as NSData, typeIdentifier: png)
        let image = try XCTUnwrap(ComposerPaste.classify([data]).first)
        XCTAssertFalse(image.copiedAsFile)
        let loaded = try await ComposerPaste.loadData(image)
        XCTAssertEqual(loaded, bytes)
    }

    #if os(macOS)
    func testMacPasteboardFilesAndLoneImagesAttachButTextPastes() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cantrip-paste-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("paste-\(UUID().uuidString).pdf")
        try Data("%PDF".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        pasteboard.setString(file.lastPathComponent, forType: .string)
        let files = try XCTUnwrap(ComposerPaste.providers(from: pasteboard))
        XCTAssertEqual(ComposerPaste.classify(files).map(\.kind), [.file])

        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); image.unlockFocus()
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        let images = try XCTUnwrap(ComposerPaste.providers(from: pasteboard))
        XCTAssertEqual(ComposerPaste.classify(images).map(\.kind), [.image])

        pasteboard.clearContents()
        pasteboard.setData(Data("%PDF-1.4".utf8), forType: .pdf)
        let pdf = try XCTUnwrap(ComposerPaste.providers(from: pasteboard))
        XCTAssertEqual(ComposerPaste.classify(pdf).map(\.type), [.pdf], "a PDF copied as data stays a document")

        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        pasteboard.setString("A1", forType: .string)
        XCTAssertNil(ComposerPaste.providers(from: pasteboard), "text beside an image pastes as text")

        pasteboard.clearContents()
        pasteboard.setString("hello", forType: .string)
        XCTAssertNil(ComposerPaste.providers(from: pasteboard))
    }
    #endif
}
