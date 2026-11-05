import CryptoKit
import SwiftUI
import UIKit
import XCTest
@testable import Hermes

private final class MacAccessProtocol: URLProtocol {
    @MainActor static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Task { @MainActor in
            do {
                let (status, data) = try XCTUnwrap(Self.handler)(request)
                let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil))
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
}

@MainActor
final class CantripMacAccessTests: XCTestCase {
    private func model(authorize: @escaping (String) async throws -> Void) async throws -> CantripRemoteModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MacAccessProtocol.self]
        let client = URLSession(configuration: config)
        let remote = CantripRemoteModel(urlSession: client, authorizeSensitiveAction: authorize)
        let configured = await remote.configure(url: "https://mac-access.example", pairingToken: "fixture", tailscaleOnly: true)
        XCTAssertTrue(configured, remote.errorMessage ?? "")
        addTeardownBlock { @MainActor in
            remote.setAppActive(false); remote.clearConfiguration(); client.invalidateAndCancel()
            MacAccessProtocol.handler = nil
        }
        return remote
    }

    private let status = Data("""
    {"name":"Fixture Mac","desktopEnabled":true,"activeUntil":null,
     "permissions":[{"permission":"screenRecording","title":"Screen Recording","state":"notGranted"},
     {"permission":"accessibility","title":"Accessibility","state":"notGranted"},
     {"permission":"keychain","title":"Keychain","state":"needsAttention"}],
     "issues":[{"id":"3D3D0608-E1B3-4513-A2C0-FC00F4E17876","permission":"keychain","title":"Keychain needs attention on the Mac"}]}
    """.utf8)

    func testMacMenuOpensExistingDestinationsWithoutStartingMacOperations() async throws {
        let remote = try await model { _ in XCTFail("Opening a menu destination must not authenticate") }
        MacAccessProtocol.handler = { _ in
            XCTFail("Choosing a menu destination must not start a Mac operation")
            return (200, self.status)
        }
        var showingMaintenance = false
        var openings = 0
        let actions = CantripMacMenuActions(
            remote: remote,
            showingMaintenance: Binding(get: { showingMaintenance }, set: { showingMaintenance = $0 })
        ) {
            XCTAssertFalse(remote.showingMacAccess)
            XCTAssertFalse(showingMaintenance)
            openings += 1
        }

        XCTAssertTrue(actions.isEnabled)
        XCTAssertNil(remote.selectedSessionID, "Mac controls must not require a selected tab")
        XCTAssertFalse(remote.isConnected, "Configured but offline Macs still need their status screens")
        actions.openMacAccess()
        XCTAssertTrue(remote.showingMacAccess)
        XCTAssertFalse(showingMaintenance)
        XCTAssertEqual(openings, 1)

        remote.showingMacAccess = false
        actions.openMaintenance()
        XCTAssertTrue(showingMaintenance)
        XCTAssertFalse(remote.showingMacAccess)
        XCTAssertEqual(openings, 2)

        remote.clearConfiguration()
        let rebuilt = CantripMacMenuActions(remote: remote, showingMaintenance: .constant(false)) {}
        XCTAssertFalse(rebuilt.isEnabled)
    }

    func testBiometricFailureBlocksApprovalSecretAndDesktopWithoutNetwork() async throws {
        var attempts = 0
        let remote = try await model { _ in attempts += 1; throw CancellationError() }
        MacAccessProtocol.handler = { _ in XCTFail("No request before biometric success"); return (200, self.status) }
        for answer in [CantripInputAnswer(decision: "approve"), CantripInputAnswer(decision: "submit", text: "synthetic-secret")] {
            let success = await remote.respondToInput(sessionID: UUID().uuidString, id: UUID(), answer: answer, identity: remote.usageIdentity)
            XCTAssertFalse(success)
        }
        do { _ = try await remote.startDesktop(control: true, identity: remote.usageIdentity); XCTFail("Expected cancellation") }
        catch is CancellationError {}
        XCTAssertEqual(attempts, 3)
        XCTAssertNotNil(Bundle.main.object(forInfoDictionaryKey: "NSFaceIDUsageDescription"))
    }

    func testDenyAndCancelDoNotRequireBiometrics() async throws {
        let remote = try await model { _ in XCTFail("Deny and Cancel must remain available") }
        let id = UUID()
        MacAccessProtocol.handler = { request in
            if request.httpMethod == "GET" {
                return (200, Data("""
                {"requests":[{"id":"\(id)","kind":"approval","title":"Approve","source":"fixture","detail":"",
                  "choices":[],"allowsFreeform":false,"expiresAt":\(Date().addingTimeInterval(600).timeIntervalSince1970)}]}
                """.utf8))
            }
            return (200, Data(#"{"accepted":true}"#.utf8))
        }
        for decision in ["deny", "cancel"] {
            let success = await remote.respondToInput(sessionID: UUID().uuidString, id: id,
                answer: .init(decision: decision), identity: remote.usageIdentity)
            XCTAssertTrue(success, remote.errorMessage ?? "")
        }
    }

    func testChangingMacWhileAuthenticatingCannotStartDesktop() async throws {
        var continuation: CheckedContinuation<Void, Error>?
        let remote = try await model { _ in try await withCheckedThrowingContinuation { continuation = $0 } }
        let identity = remote.usageIdentity
        let task = Task { try await remote.startDesktop(control: false, identity: identity) }
        for _ in 0..<50 where continuation == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(continuation)
        let changed = await remote.configure(url: "https://another-mac.example", pairingToken: "other", tailscaleOnly: true)
        XCTAssertTrue(changed)
        MacAccessProtocol.handler = { _ in XCTFail("Old authorization must not reach a new Mac"); return (200, self.status) }
        continuation?.resume()
        do { _ = try await task.value; XCTFail("Expected identity cancellation") }
        catch is CancellationError {}
    }

    func testStartRequiresBiometricThenPinnedPreflightAndSinglePost() async throws {
        var authenticated = false, methods: [String] = []
        let remote = try await model { _ in authenticated = true }
        let leaseID = UUID()
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
        MacAccessProtocol.handler = { request in
            XCTAssertTrue(authenticated)
            methods.append("\(request.httpMethod!) \(request.url!.path)")
            if request.httpMethod == "GET" { return (200, self.status) }
            return (200, Data("""
            {"id":"\(leaseID)","token":"lease-token","key":"\(key)","control":false,
            "expiresAt":\(Date().addingTimeInterval(300).timeIntervalSince1970),
            "displays":[{"id":1,"name":"Main","x":0,"y":0,"width":1440,"height":900}]}
            """.utf8))
        }
        let lease = try await remote.startDesktop(control: false, identity: remote.usageIdentity)
        XCTAssertEqual(lease.id, leaseID)
        XCTAssertEqual(methods, ["GET /api/v1/mac-access", "POST /api/v1/desktop/start"])
        methods = []
        MacAccessProtocol.handler = { request in
            methods.append(request.httpMethod!)
            if request.httpMethod == "POST" { throw URLError(.networkConnectionLost) }
            return (200, self.status)
        }
        do { _ = try await remote.startDesktop(control: true, identity: remote.usageIdentity); XCTFail("Lost acknowledgement must surface") }
        catch { XCTAssertTrue(error.localizedDescription.contains("may have reached")) }
        XCTAssertEqual(methods, ["GET", "POST"])
    }

    func testBiometricSuccessWaitsForForegroundBeforeDesktopRequests() async throws {
        var state = UIApplication.State.active
        let notifications = NotificationCenter()
        var evaluated = false, methods: [String] = []
        let remote = try await model { _ in
            try await CantripBiometrics.authorize(applicationState: { state }, notifications: notifications, evaluate: {
                state = .inactive
                evaluated = true
                return true
            }, invalidate: {})
        }
        MacAccessProtocol.handler = { request in
            XCTAssertEqual(state, .active)
            methods.append(request.httpMethod!)
            if request.httpMethod == "GET" { return (200, self.status) }
            return (200, Data("""
            {"id":"\(UUID())","token":"fixture","key":"\(Data(repeating: 1, count: 32).base64EncodedString())",
             "control":true,"expiresAt":\(Date().addingTimeInterval(300).timeIntervalSince1970),"displays":[]}
            """.utf8))
        }
        let task = Task { try await remote.startDesktop(control: true, identity: remote.usageIdentity) }
        for _ in 0..<50 where !evaluated { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(evaluated)
        XCTAssertTrue(methods.isEmpty, "Face ID success alone must not send while inactive")
        state = .active
        notifications.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        let lease = try await task.value
        XCTAssertTrue(lease.control)
        XCTAssertEqual(methods, ["GET", "POST"])
    }

    func testBackgroundDuringBiometricsCannotAuthorizeAfterReturningToForeground() async throws {
        var state = UIApplication.State.active, invalidations = 0
        let notifications = NotificationCenter()
        let remote = try await model { _ in
            try await CantripBiometrics.authorize(applicationState: { state }, notifications: notifications, evaluate: {
                state = .background
                notifications.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
                XCTAssertGreaterThan(invalidations, 0)
                state = .active
                notifications.post(name: UIApplication.didBecomeActiveNotification, object: nil)
                return true
            }, invalidate: { invalidations += 1 })
        }
        MacAccessProtocol.handler = { _ in XCTFail("Backgrounded authentication must not send"); return (200, self.status) }
        do { _ = try await remote.startDesktop(control: false, identity: remote.usageIdentity); XCTFail("Expected cancellation") }
        catch is CancellationError {}
    }

    func testBackgroundOrCancellationWhileWaitingForForegroundRejectsAuthentication() async throws {
        for background in [true, false] {
            var state = UIApplication.State.active, evaluated = false, invalidated = false
            let notifications = NotificationCenter()
            let task = Task {
                try await CantripBiometrics.authorize(applicationState: { state }, notifications: notifications, evaluate: {
                    state = .inactive
                    evaluated = true
                    return true
                }, invalidate: { invalidated = true })
            }
            for _ in 0..<50 where !evaluated { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(evaluated)
            if background {
                state = .background
                notifications.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
            } else {
                task.cancel()
            }
            do { try await task.value; XCTFail("Expected cancellation") }
            catch is CancellationError {}
            XCTAssertTrue(invalidated)
            state = .active
            notifications.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        }
    }

    func testCancellingPendingBiometricEvaluationInvalidatesContext() async throws {
        var pending: CheckedContinuation<Bool, Error>?
        var invalidated = false
        let task = Task {
            try await CantripBiometrics.authorize(applicationState: { .active }, notifications: NotificationCenter(), evaluate: {
                try await withCheckedThrowingContinuation { pending = $0 }
            }, invalidate: {
                invalidated = true
                let continuation = pending
                pending = nil
                continuation?.resume(throwing: CancellationError())
            })
        }
        for _ in 0..<50 where pending == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(pending)
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        XCTAssertTrue(invalidated)
    }

    func testBiometricForegroundWaitTimesOutWithoutAuthorizing() async throws {
        var state = UIApplication.State.active, invalidated = false
        do {
            try await CantripBiometrics.authorize(applicationState: { state }, notifications: NotificationCenter(),
                activationTimeout: .milliseconds(20), evaluate: {
                    state = .inactive
                    return true
                }, invalidate: { invalidated = true })
            XCTFail("An inactive app must not authorize")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("did not become active"), error.localizedDescription)
        }
        XCTAssertTrue(invalidated)
    }

    func testBiometricFailureAndInitiallyInactiveAppCannotAuthorize() async throws {
        for initialState in [UIApplication.State.active, .inactive, .background] {
            var evaluated = false
            do {
                try await CantripBiometrics.authorize(applicationState: { initialState }, notifications: NotificationCenter(), evaluate: {
                    evaluated = true
                    return false
                }, invalidate: {})
                XCTFail("Expected rejection")
            } catch is CancellationError {
                XCTAssertNotEqual(initialState, .active)
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("did not succeed"), error.localizedDescription)
            }
            XCTAssertEqual(evaluated, initialState == .active)
        }
    }

    func testClosingDesktopDuringAuthenticationCannotStartSession() async throws {
        var state = UIApplication.State.active, evaluated = false
        let notifications = NotificationCenter()
        let remote = try await model { _ in
            try await CantripBiometrics.authorize(applicationState: { state }, notifications: notifications, evaluate: {
                state = .inactive
                evaluated = true
                return true
            }, invalidate: {})
        }
        MacAccessProtocol.handler = { _ in XCTFail("Done must cancel the pending start"); return (200, self.status) }
        let desktop = CantripDesktopModel(remote: remote)
        let task = Task { await desktop.start(control: true) }
        for _ in 0..<50 where !evaluated { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(evaluated)
        await desktop.stop()
        state = .active
        notifications.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        await task.value
        XCTAssertNil(desktop.lease)
        XCTAssertFalse(desktop.busy)
        XCTAssertNotNil(desktop.error)
    }

    func testControlPreferenceSurvivesReopeningWithoutStartingSession() async throws {
        let suite = "CantripMacAccessTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = try await model { _ in XCTFail("A saved preference is not authorization") }
        MacAccessProtocol.handler = { _ in
            XCTFail("Changing the preference must not reach the Mac")
            return (200, self.status)
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        for expected in [false, true, false] {
            let controller = UIHostingController(rootView:
                CantripDesktopStartCard(macName: "Fixture Mac", busy: false, error: nil, onStart: {
                    XCTFail("Changing the preference must not start a session")
                }, onOpenPermissions: {}, onClose: {})
                .defaultAppStorage(defaults))
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }
            try await Task.sleep(for: .milliseconds(350))
            controller.view.layoutIfNeeded()
            let toggle = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? UISwitch }.first)
            XCTAssertEqual(toggle.isOn, expected)
            toggle.setOn(!expected, animated: false)
            toggle.sendActions(for: .valueChanged)
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(defaults.bool(forKey: "cantrip.desktop.control"), !expected)
        }
    }

    func testFrameAndKeyboardCiphertextAreBoundToLeaseFrameAndSequence() throws {
        let key = SymmetricKey(size: .bits256), leaseID = UUID(), frameID = UUID()
        let lease = CantripDesktopLease(id: leaseID, token: "fixture",
            key: key.withUnsafeBytes { Data($0).base64EncodedString() }, expiresAt: 9999999999, control: true, displays: [])
        let display = CantripDesktopDisplay(id: 2, name: "Left", x: -1440, y: 0, width: 1440, height: 900)
        let ad = Data("cantrip-desktop|\(leaseID)|\(frameID)|2|800|500".utf8)
        let plain = Data("synthetic-screen".utf8)
        let sealed = try AES.GCM.seal(plain, using: key, authenticating: ad).combined!
        let frame = CantripDesktopFrame(id: frameID, display: display, width: 800, height: 500, encryptedJPEG: sealed.base64EncodedString())
        XCTAssertEqual(try frame.decrypt(lease: lease), plain)
        let changed = CantripDesktopFrame(id: UUID(), display: display, width: 800, height: 500, encryptedJPEG: sealed.base64EncodedString())
        XCTAssertThrowsError(try changed.decrypt(lease: lease))
        let command = CantripDesktopCommand(frameID: frameID, kind: "text", text: "synthetic-password")
        let cipher = try command.encrypted(lease: lease, sequence: 1)
        XCTAssertFalse(cipher.contains("synthetic-password"))
        let decoded = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(base64Encoded: cipher)!), using: key,
            authenticating: Data("cantrip-desktop|\(leaseID)|input|1".utf8))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: decoded) as? [String: String])
        XCTAssertEqual(body["text"], "synthetic-password")
        XCTAssertThrowsError(try AES.GCM.open(AES.GCM.SealedBox(combined: Data(base64Encoded: cipher)!), using: key,
            authenticating: Data("cantrip-desktop|\(leaseID)|input|2".utf8)))
    }

    func testTypingQueueMergesKeysTypedWhileAnInputIsOnItsWay() {
        var queue = CantripDesktopTypingQueue()
        queue.type("he"); queue.type("l"); queue.type("lo\nok\t")
        XCTAssertEqual(queue.pending, [.text("hello"), .key("return"), .text("ok"), .key("tab")])
        XCTAssertEqual(queue.next(), .text("hello"))
        queue.press("escape")
        XCTAssertEqual(queue.pending, [.key("return"), .text("ok"), .key("tab"), .key("escape")])

        // Delete takes back what hasn't left; with nothing waiting it deletes on the Mac.
        queue = CantripDesktopTypingQueue()
        queue.type("ab"); queue.deleteBackward()
        XCTAssertEqual(queue.pending, [.text("a")])
        queue.deleteBackward()
        XCTAssertTrue(queue.isEmpty)
        queue.deleteBackward()
        XCTAssertEqual(queue.pending, [.key("delete")])

        // One input never carries more than the Mac takes.
        queue = CantripDesktopTypingQueue()
        queue.type(String(repeating: "a", count: CantripDesktopTypingQueue.maxTextBytes - 1))
        queue.type("é")
        XCTAssertEqual(queue.pending.count, 2)
        queue.clear()
        XCTAssertNil(queue.next())
    }

    func testFullScreenFitsTheMacAndMapsTouchesToIt() {
        let image = CGSize(width: 1600, height: 1000)
        XCTAssertEqual(CantripDesktopFit.fitScale(image: image, in: CGSize(width: 800, height: 800)), 0.5)
        XCTAssertEqual(CantripDesktopFit.fitScale(image: image, in: CGSize(width: 1200, height: 500)), 0.5,
                       "Fits the shorter side, e.g. above the keyboard")
        XCTAssertEqual(CantripDesktopFit.fitScale(image: .zero, in: CGSize(width: 800, height: 800)), 1)

        let shown = CGSize(width: 800, height: 500)
        XCTAssertEqual(CantripDesktopFit.point(CGPoint(x: 400, y: 125), in: shown), CGPoint(x: 0.5, y: 0.25))
        XCTAssertEqual(CantripDesktopFit.point(CGPoint(x: 800, y: 500), in: shown)?.x ?? 1, 0.999999, accuracy: 1e-9)
        XCTAssertNil(CantripDesktopFit.point(CGPoint(x: -1, y: 10), in: shown), "A tap off the screen clicks nothing")
        XCTAssertNil(CantripDesktopFit.point(CGPoint(x: 10, y: 501), in: shown))
        // A drag that runs off the screen lets go at its edge.
        XCTAssertEqual(CantripDesktopFit.clampedPoint(CGPoint(x: -40, y: 250), in: shown), CGPoint(x: 0, y: 0.5))
        XCTAssertEqual(CantripDesktopFit.clampedPoint(CGPoint(x: 900, y: 600), in: shown)?.y ?? 0, 0.999999, accuracy: 1e-9)

        XCTAssertEqual(CantripDesktopFit.remaining(until: 1_000_245, now: Date(timeIntervalSince1970: 1_000_000)), "4:05")
        XCTAssertEqual(CantripDesktopFit.remaining(until: 1_000_000, now: Date(timeIntervalSince1970: 1_000_010)), "0:00")
    }

    func testScreenFitsPinchesAndKeepsOneFingerForTheMac() throws {
        let screen = CantripDesktopScreenView(frame: CGRect(x: 0, y: 0, width: 800, height: 800))
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 1000)).image { context in
            UIColor.gray.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1600, height: 1000))
        }
        screen.show(image)
        screen.layoutIfNeeded()
        XCTAssertEqual(screen.zoomScale, 0.5, accuracy: 0.001, "Starts fitted")
        XCTAssertEqual(screen.minimumZoomScale, 0.5, accuracy: 0.001)
        XCTAssertEqual(screen.maximumZoomScale, 0.5 * CantripDesktopFit.maxZoom, accuracy: 0.001, "Pinch zooms in up to 4×")
        XCTAssertEqual(screen.contentInset.top, 150, accuracy: 0.5, "Centered between the bands")

        // The keyboard takes room: a fitted screen stays fitted.
        screen.frame = CGRect(x: 0, y: 0, width: 800, height: 400)
        screen.layoutIfNeeded()
        XCTAssertEqual(screen.zoomScale, 0.4, accuracy: 0.001)
        // Zoomed in, it stays zoomed when the room changes, and Fit brings it back.
        screen.zoomScale = 1.2
        screen.frame = CGRect(x: 0, y: 0, width: 800, height: 800)
        screen.layoutIfNeeded()
        XCTAssertEqual(screen.zoomScale, 1.2, accuracy: 0.001)
        screen.fit()
        XCTAssertEqual(screen.zoomScale, 0.5, accuracy: 0.001)

        // View only: one finger moves the zoomed screen. In control: one finger is the Mac's.
        XCTAssertEqual(screen.panGestureRecognizer.minimumNumberOfTouches, 1)
        screen.controls = true
        XCTAssertEqual(screen.panGestureRecognizer.minimumNumberOfTouches, 1, "A Mac without drags keeps one-finger panning")
        screen.dragsOnMac = true
        XCTAssertEqual(screen.panGestureRecognizer.minimumNumberOfTouches, 2, "Two fingers move the zoomed screen")
        XCTAssertNotNil(screen.pinchGestureRecognizer)
        XCTAssertEqual(screen.imageView.accessibilityIdentifier, "desktop.fullScreen.screen")
        XCTAssertTrue(screen.imageView.accessibilityTraits.contains(.allowsDirectInteraction))
    }

    func testLiveTypingReachesTheMacInOrderOneInputAtATime() async throws {
        let remote = try await model { _ in }
        let leaseID = UUID(), frameID = UUID()
        let key = SymmetricKey(size: .bits256)
        let keyText = key.withUnsafeBytes { Data($0).base64EncodedString() }
        let jpeg = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 16, height: 10)).image { context in
            UIColor.gray.setFill(); context.fill(CGRect(x: 0, y: 0, width: 16, height: 10))
        }.jpegData(compressionQuality: 0.8))
        let sealed = try AES.GCM.seal(jpeg, using: key,
            authenticating: Data("cantrip-desktop|\(leaseID)|\(frameID)|1|16|10".utf8)).combined!.base64EncodedString()
        var inputs: [(sequence: Int, kind: String, value: String)] = []
        MacAccessProtocol.handler = { request in
            switch request.url!.path {
            case "/api/v1/mac-access": return (200, self.status)
            case "/api/v1/desktop/start":
                return (200, Data("""
                {"id":"\(leaseID)","token":"lease-token","key":"\(keyText)","control":true,
                "expiresAt":\(Date().addingTimeInterval(300).timeIntervalSince1970),
                "displays":[{"id":1,"name":"Main","x":0,"y":0,"width":1440,"height":900}]}
                """.utf8))
            case "/api/v1/desktop/frame":
                return (200, Data("""
                {"id":"\(frameID)","display":{"id":1,"name":"Main","x":0,"y":0,"width":1440,"height":900},
                "width":16,"height":10,"encryptedJPEG":"\(sealed)"}
                """.utf8))
            case "/api/v1/desktop/input":
                let body = try self.body(request)
                let sequence = try XCTUnwrap(body["sequence"] as? Int)
                let cipher = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(body["encrypted"] as? String)))
                let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: cipher), using: key,
                                             authenticating: Data("cantrip-desktop|\(leaseID)|input|\(sequence)".utf8))
                let command = try XCTUnwrap(JSONSerialization.jsonObject(with: plain) as? [String: Any])
                XCTAssertEqual(command["frameID"] as? String, frameID.uuidString)
                let kind = try XCTUnwrap(command["kind"] as? String)
                inputs.append((sequence, kind, (command["text"] ?? command["key"]) as? String ?? ""))
                return (200, Data(#"{"accepted":true}"#.utf8))
            case "/api/v1/desktop/stop": return (200, Data(#"{"stopped":true}"#.utf8))
            default: XCTFail("Unexpected \(request.url!.path)"); return (404, Data())
            }
        }
        let desktop = CantripDesktopModel(remote: remote)
        await desktop.start(control: true)
        XCTAssertNil(desktop.error)
        for _ in 0..<50 where desktop.frame == nil { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNotNil(desktop.frame, "The first screen arrives")

        // Typed before the first input leaves: they go in order, merged, and "d" is taken back unsent.
        desktop.type("ab")
        desktop.press("return")
        desktop.type("c")
        desktop.type("d")
        desktop.deleteBackward()
        desktop.type("\t")
        for _ in 0..<100 where inputs.count < 4 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(inputs.map(\.kind), ["text", "key", "text", "key"])
        XCTAssertEqual(inputs.map(\.value), ["ab", "return", "c", "tab"])
        XCTAssertEqual(inputs.map(\.sequence), [1, 2, 3, 4], "Each input after the last, never two at once")
        await desktop.stop()
        XCTAssertNil(desktop.lease)
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testMacPermissionsFormFitsAccessibleNarrowAndTabletLayouts() async throws {
        let remote = try await model { _ in XCTFail("Opening permissions must not start biometrics or viewing") }
        MacAccessProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/v1/mac-access")
            return (200, self.status)
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        for width: CGFloat in [320, 768] {
            for size: DynamicTypeSize in [.large, .accessibility3] {
                let view = NavigationStack { CantripMacAccessView(remote: remote) }.environment(\.dynamicTypeSize, size)
                let controller = UIHostingController(rootView: view)
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: width, height: 700)
                window.rootViewController = controller; window.makeKeyAndVisible()
                defer { window.isHidden = true }
                try await Task.sleep(for: .milliseconds(350))
                controller.view.layoutIfNeeded()
                func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
                for scroll in descendants(controller.view).compactMap({ $0 as? UIScrollView }) where scroll.bounds.width > 0 {
                    XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
                }
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                let attachment = XCTAttachment(image: image); attachment.name = "Mac Access \(Int(width)) \(size)"
                attachment.lifetime = .keepAlways; add(attachment)
            }
        }
    }
}
