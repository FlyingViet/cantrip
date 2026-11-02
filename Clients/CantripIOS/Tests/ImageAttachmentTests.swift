import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import Hermes

final class ImageAttachmentTests: XCTestCase {
    private func imageData(width: Int = 320, height: Int = 180) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height), format: format
        )
        return try XCTUnwrap(renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }.pngData())
    }

    func testScreenshotBecomesBoundedJPEG() throws {
        let attachment = try ImageAttachmentProcessor.prepare(imageData(width: 3000, height: 1500))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(attachment.data as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 2048)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 1024)
        XCTAssertLessThanOrEqual(attachment.data.count, ImageAttachmentProcessor.maximumImageBytes)
        XCTAssertNotNil(attachment.preview)
    }

    func testImportStripsLocationAndCorrectsOrientation() throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(try imageData() as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:09:06 12:00:00",
                kCGImagePropertyExifBodySerialNumber: "private-camera-id",
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 47.0,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 122.0,
                kCGImagePropertyGPSLongitudeRef: "W",
            ],
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let attachment = try ImageAttachmentProcessor.prepare(data as Data)
        let output = try XCTUnwrap(CGImageSourceCreateWithData(attachment.data as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(output, 0, nil) as? [CFString: Any]
        )
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertNil(exif?[kCGImagePropertyExifDateTimeOriginal])
        XCTAssertNil(exif?[kCGImagePropertyExifBodySerialNumber])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 180)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 320)
    }

    func testInvalidAndOversizedSourcesAreRejected() {
        XCTAssertThrowsError(try ImageAttachmentProcessor.prepare(Data("not an image".utf8)))
        XCTAssertThrowsError(try ImageAttachmentProcessor.prepare(Data()))
        XCTAssertThrowsError(try ImageAttachmentProcessor.prepare(
            Data(repeating: 0, count: ImageAttachmentProcessor.maximumSourceBytes + 1)
        ))
    }

    func testImagePayloadPreservesPixelsAndDeliveryMode() throws {
        let image = try ImageAttachmentProcessor.prepare(imageData())
        for mode in CantripDeliveryMode.allCases {
            let encoded = try JSONEncoder().encode(
                CantripMessageBody(text: "", mode: mode, images: [image])
            )
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertEqual(body["text"] as? String, "")
            XCTAssertEqual(body["mode"] as? String, mode.rawValue)
            let images = try XCTUnwrap(body["images"] as? [[String: String]])
            XCTAssertEqual(images.count, 1)
            XCTAssertEqual(images.first?["data"], image.data.base64EncodedString())
        }
    }

    func testTextOnlyPayloadRemainsBackwardCompatible() throws {
        let encoded = try JSONEncoder().encode(
            CantripMessageBody(text: "Hello", mode: .queue, images: [])
        )
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(body["text"] as? String, "Hello")
        XCTAssertNil(body["images"])
    }

    func testLegacyRemoteDoesNotAdvertiseImages() throws {
        var body: [String: Any] = [
            "id": "session", "title": "Test", "workdir": "/tmp",
            "isStreaming": false, "canResume": false, "councilMode": false,
            "queuedCount": 0,
        ]
        func decode() throws -> CantripRemoteSession {
            try JSONDecoder().decode(
                CantripRemoteSession.self,
                from: JSONSerialization.data(withJSONObject: body)
            )
        }
        XCTAssertNil(try decode().supportsImageAttachments)
        body["supportsImageAttachments"] = false
        XCTAssertEqual(try decode().supportsImageAttachments, false)
        body["supportsImageAttachments"] = true
        XCTAssertEqual(try decode().supportsImageAttachments, true)
    }
}
