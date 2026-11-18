import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Hermes

@MainActor
final class CantripPrivateMascotTests: XCTestCase {
    private let revision = String(repeating: "a", count: 64)

    private func png(_ size: Int = 16, red: CGFloat = 0.6) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: red, green: 0.3, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func payload(revision: String? = nil, size: Int = 16) throws -> CantripPrivateMascot.Payload {
        try .init(version: 1, revision: revision ?? self.revision, sparkX: 0.8, sparkY: 0.6,
                  portrait: png(size), blink: png(size, red: 0.1))
    }

    private func waitFor(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !predicate(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(predicate())
    }

    func testPayloadChecksRevisionDimensionsAndPNG() throws {
        let valid = try payload()
        let pack = try CantripPrivateMascot(valid, revision: revision)
        XCTAssertEqual(pack.portrait.width, 16)
        XCTAssertThrowsError(try CantripPrivateMascot(valid, revision: String(repeating: "b", count: 64)))
        XCTAssertThrowsError(try CantripPrivateMascot(payload(size: 1025), revision: revision))
        let invalid = CantripPrivateMascot.Payload(
            version: 1, revision: revision, sparkX: 0.8, sparkY: 0.6,
            portrait: Data("not PNG".utf8), blink: valid.blink
        )
        XCTAssertThrowsError(try CantripPrivateMascot(invalid, revision: revision))
    }

    func testStoreLoadsOnceAndRemovalDropsArtwork() async throws {
        let store = CantripPrivateMascotStore()
        let value = try payload()
        var loads = 0
        let load: @MainActor (String) async throws -> CantripPrivateMascot.Payload = { _ in
            loads += 1
            return value
        }
        store.update(revision: revision, load: load)
        try await waitFor { store.pack != nil }
        store.update(revision: revision, load: load)
        await Task.yield()
        XCTAssertEqual(loads, 1)
        store.update(revision: nil, load: load)
        XCTAssertNil(store.pack)
        XCTAssertNil(store.error)
    }

    func testServerSwitchDiscardsLateArtwork() async throws {
        let store = CantripPrivateMascotStore()
        let value = try payload()
        var pending: CheckedContinuation<CantripPrivateMascot.Payload, Never>?
        store.update(revision: revision) { _ in
            await withCheckedContinuation { pending = $0 }
        }
        try await waitFor { pending != nil }
        store.reset()
        pending?.resume(returning: value)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(store.pack)
        XCTAssertNil(store.error)
    }

    func testFailuresAreVisibleAndThrottledButNewRevisionCanLoad() async throws {
        let store = CantripPrivateMascotStore()
        var loads = 0
        let fail: @MainActor (String) async throws -> CantripPrivateMascot.Payload = { _ in
            loads += 1
            throw CantripRemoteError.invalidResponse
        }
        store.update(revision: revision, load: fail)
        try await waitFor { store.error != nil }
        store.update(revision: revision, load: fail)
        await Task.yield()
        XCTAssertEqual(loads, 1)
        let newer = String(repeating: "b", count: 64)
        let value = try payload(revision: newer)
        store.update(revision: newer) { _ in value }
        try await waitFor { store.pack?.revision == newer }
        XCTAssertNil(store.error)
        store.update(revision: nil, hostError: "Repair the mascot pack.") { _ in value }
        XCTAssertNil(store.pack)
        XCTAssertEqual(store.error, "Repair the mascot pack.")
    }

    func testReducedMotionIsStillAndLivePoseBlinksAndCelebrates() {
        typealias Pose = CantripPrivateMascotRenderer.Pose
        let still = Pose(mood: .thinking, time: 0, motion: false, celebration: nil)
        XCTAssertEqual(still, Pose(mood: .thinking, time: 4.7, motion: false, celebration: 0.3))
        XCTAssertFalse(still.closedEyes)
        XCTAssertTrue(Pose(mood: .idle, time: 4.7, motion: true, celebration: nil).closedEyes)
        XCTAssertFalse(Pose(mood: .idle, time: 1, motion: true, celebration: nil).closedEyes)
        XCTAssertTrue(Pose(mood: .sleeping, time: 1, motion: false, celebration: nil).closedEyes)
        XCTAssertGreaterThan(Pose(mood: .idle, time: 1, motion: true, celebration: 0.3).hop, 0)
    }

    func testPrivateFramesRenderInExistingMascotView() throws {
        let pack = try CantripPrivateMascot(payload(), revision: revision)
        for mood in [CantripMascotMood.idle, .thinking, .sleeping] {
            let renderer = ImageRenderer(
                content: CantripMascotView(mood: mood, size: 88, frameTime: 1)
                    .environment(\.cantripPrivateMascot, pack)
            )
            XCTAssertNotNil(renderer.cgImage)
        }
    }
}
