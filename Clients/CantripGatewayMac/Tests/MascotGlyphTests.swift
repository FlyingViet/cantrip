import AppKit
import SwiftUI
import XCTest
@testable import Hermes

/// Pip's mood marks are filled glyph outlines (animated text leaked glyph bitmaps on macOS).
@MainActor
final class MascotGlyphTests: XCTestCase {
    private func inkBounds(_ view: some View) throws -> CGRect {
        let renderer = ImageRenderer(content: view.frame(width: 60, height: 60))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 128 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        XCTAssertGreaterThan(maxX, minX, "Something was drawn")
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The outline lands where `GraphicsContext.draw(Text)` put the glyph, at the same size.
    func testOutlinesMatchTheTextTheyReplace() throws {
        let center = CGPoint(x: 30, y: 30)
        for character in ["z", "?"] {
            for size in [8.8, 11.0, 14.1] {
                let text = try inkBounds(Canvas { context, _ in
                    context.draw(Text(character).font(.system(size: size, weight: .heavy, design: .rounded))
                        .foregroundColor(.white), at: center)
                })
                let outline = CantripMascotRenderer.GlyphOutline(Character(character))
                let filled = try inkBounds(Canvas { context, _ in
                    outline.draw(in: &context, at: center, size: size, color: .white)
                })
                for (a, b) in [(text.minX, filled.minX), (text.maxX, filled.maxX), (text.minY, filled.minY), (text.maxY, filled.maxY)] {
                    XCTAssertEqual(a, b, accuracy: 2, "\(character) at \(size)pt: text \(text) vs outline \(filled)")
                }
            }
        }
    }

    func testSleepingAndCuriousPipStillRender() throws {
        for mood in [CantripMascotMood.sleeping, .curious] {
            let renderer = ImageRenderer(content: CantripMascotView(mood: mood, size: 88, frameTime: 1.3))
            XCTAssertNotNil(renderer.cgImage, "\(mood)")
        }
    }
}
