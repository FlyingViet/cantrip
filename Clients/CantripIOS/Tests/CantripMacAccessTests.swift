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
        let remote = try await model { _ in XCTFail("A saved preference is not authorization") }
        MacAccessProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/v1/mac-access")
            return (200, self.status)
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
        for expected in [false, true, false] {
            let controller = UIHostingController(rootView:
                NavigationStack { CantripMacAccessView(remote: remote) }.defaultAppStorage(defaults))
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
