import AppKit
import ApplicationServices

// MARK: - Signing in again through Chrome (docs/muse.md "Staying signed in")

/// What the sign-in may do on a page Chrome shows, from its accessible elements: press only a
/// remembered-account button ("Continue as …"; on auth.meta.com a lone "Continue" with nothing to
/// fill in), and stop when the page wants a password or code. It never types anything.
enum MuseSignInPage {
    struct Element: Equatable {
        var role: String
        var subrole: String? = nil
        /// Title, description or value, whichever the element has.
        var label: String
        var placeholder: String? = nil
    }

    enum Step: Equatable {
        case press(Int)
        case needsYou(String)
        case wait
    }

    static let hosts: Set<String> = ["muse.ai", "www.muse.ai", "auth.meta.com"]

    static func step(host: String, elements: [Element], hosts: Set<String> = MuseSignInPage.hosts) -> Step {
        guard hosts.contains(host.lowercased()) else { return .wait }
        func lower(_ text: String?) -> String { (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let fields = elements.filter { $0.role == "AXTextField" || $0.role == "AXTextArea" }
        if fields.contains(where: { $0.subrole == "AXSecureTextField" || lower($0.label + " " + ($0.placeholder ?? "")).contains("password") }) {
            return .needsYou("the sign-in asks for your password")
        }
        if fields.contains(where: { let text = lower($0.label + " " + ($0.placeholder ?? "")); return text.contains("code") }) {
            return .needsYou("the sign-in asks for a code")
        }
        let remembered = try! NSRegularExpression(pattern: #"^(continue|log in|login|sign in) as\s+\S"#)
        for (index, element) in elements.enumerated() where element.role == "AXButton" || element.role == "AXLink" {
            let label = lower(element.label)
            guard !label.contains("another"), !label.contains("not you") else { continue }
            if remembered.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)) != nil { return .press(index) }
        }
        if host.lowercased() == "auth.meta.com", fields.isEmpty,
           let index = elements.firstIndex(where: { $0.role == "AXButton" && lower($0.label) == "continue" }) {
            return .press(index)
        }
        return .wait
    }
}

/// Opens muse.ai in the user's own Chrome (the profile with the muse.ai login, never the agent
/// Chrome) and presses the remembered-account button through Accessibility, as VoiceOver would.
/// Done when `signedIn` says Chrome has a newer muse.ai login; then the tab is closed. Otherwise the
/// tab stays open for the user to finish (View Mac).
@MainActor
final class MuseChromeSignIn {
    enum Outcome: Equatable {
        case signedIn
        /// The page needs the user (a password, a code, no remembered account): the tab stays open.
        case needsYou(String)
        /// It couldn't try: no Accessibility access, no Chrome.
        case unavailable(String)
    }

    var chromeApp = URL(fileURLWithPath: "/Applications/Google Chrome.app")
    var chromeSupport = MuseLoginFiles.chromeSupport
    var url = URL(string: "https://muse.ai/")!
    var hosts = MuseSignInPage.hosts
    var timeout: TimeInterval = 75
    var maxPresses = 3
    var log: (String) -> Void = { _ in }

    func run(profile: String, signedIn: @escaping () -> Bool) async -> Outcome {
        guard AXIsProcessTrusted() else { return .unavailable("Cantrip doesn't have Accessibility access on this Mac") }
        guard FileManager.default.fileExists(atPath: chromeApp.path) else { return .unavailable("Chrome isn't installed on this Mac") }
        // A new process with the profile hands the page to the user's running Chrome (or starts it),
        // and never reaches the agent Chrome, which has its own profile folder.
        let arguments = ["-n", "-g", "-a", chromeApp.path, "--args", "--profile-directory=\(profile)", url.absoluteString]
        let opened = await Task.detached { try? ProcessRunner.run("/usr/bin/open", arguments, timeout: 20) }.value
        guard opened?.succeeded == true else { return .unavailable("Chrome didn't open muse.ai") }
        log("opened muse.ai in Chrome (\(profile)) to sign in with the remembered account")
        let deadline = Date().addingTimeInterval(timeout)
        var presses = 0
        var lastReason: String?
        var app: AXUIElement?
        defer { if let app { _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) } }
        while Date() < deadline {
            if signedIn() {
                if let app, let page = page(in: app) { close(page.window) }
                log("Chrome signed in again")
                return .signedIn
            }
            if app == nil, let pid = chromePID() {
                let element = AXUIElementCreateApplication(pid)
                // Chrome builds its web pages' accessibility tree once an assistive app asks.
                _ = AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
                app = element
            }
            if let app, let page = page(in: app) {
                let found = elements(in: page.webArea)
                switch MuseSignInPage.step(host: page.host, elements: found.map(\.element), hosts: hosts) {
                case .press(let index) where presses < maxPresses:
                    presses += 1
                    let result = AXUIElementPerformAction(found[index].ui, kAXPressAction as CFString)
                    log("pressed the remembered-account button (\(presses)) on \(page.host)\(result == .success ? "" : ", error \(result.rawValue)")")
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    continue
                case .needsYou(let reason):
                    // Twice in a row, so a page still loading isn't taken for one that asks.
                    if lastReason == reason { return .needsYou(reason) }
                    lastReason = reason
                default:
                    lastReason = nil
                }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return .needsYou(presses > 0 ? "Chrome didn't finish signing in after Continue" : "muse.ai in Chrome didn't offer your remembered account")
    }

    /// The user's Chrome: the process holding its profile folder's lock (`host-PID`).
    private func chromePID() -> pid_t? {
        let lock = chromeSupport.appendingPathComponent("SingletonLock").path
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: lock),
              let pid = target.split(separator: "-").last.flatMap({ pid_t($0) }), kill(pid, 0) == 0 else { return nil }
        return pid
    }

    private struct Found {
        var element: MuseSignInPage.Element
        var ui: AXUIElement
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    /// The first window whose shown page is on one of `hosts` (each window shows its selected tab's page).
    private func page(in app: AXUIElement) -> (window: AXUIElement, webArea: AXUIElement, host: String)? {
        for window in (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
            var budget = 400
            guard let web = first(in: window, budget: &budget, where: { self.attribute($0, kAXRoleAttribute) as? String == "AXWebArea" }),
                  let pageURL = attribute(web, "AXURL") as? URL else { continue }
            let host = pageURL.host ?? ""
            if hosts.contains(host.lowercased()) { return (window, web, host) }
        }
        return nil
    }

    private func first(in element: AXUIElement, budget: inout Int, where match: (AXUIElement) -> Bool) -> AXUIElement? {
        guard budget > 0 else { return nil }
        budget -= 1
        if match(element) { return element }
        for child in children(element) {
            if let found = first(in: child, budget: &budget, where: match) { return found }
        }
        return nil
    }

    private func elements(in webArea: AXUIElement) -> [Found] {
        var found: [Found] = []
        var budget = 3_000
        func visit(_ element: AXUIElement) {
            guard budget > 0 else { return }
            budget -= 1
            let role = attribute(element, kAXRoleAttribute) as? String ?? ""
            if ["AXButton", "AXLink", "AXTextField", "AXTextArea"].contains(role) {
                // A field's value is what's typed in it, so fields go by their name only.
                let names = role.hasPrefix("AXText") ? [kAXTitleAttribute, kAXDescriptionAttribute]
                    : [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
                let label = names.lazy.compactMap { self.attribute(element, $0) as? String }.first { !$0.isEmpty } ?? ""
                found.append(Found(element: .init(role: role, subrole: attribute(element, kAXSubroleAttribute) as? String,
                                                  label: label, placeholder: attribute(element, "AXPlaceholderValue") as? String),
                                   ui: element))
            }
            for child in children(element) { visit(child) }
        }
        visit(webArea)
        return found
    }

    /// Closes the window's selected tab (its tab strip's Close button).
    private func close(_ window: AXUIElement) {
        var budget = 600
        guard let tab = first(in: window, budget: &budget, where: {
            self.attribute($0, kAXRoleAttribute) as? String == "AXRadioButton" && (self.attribute($0, kAXValueAttribute) as? Int) == 1
        }) else { return }
        var inner = 20
        if let button = first(in: tab, budget: &inner, where: {
            self.attribute($0, kAXRoleAttribute) as? String == "AXButton" && self.attribute($0, kAXDescriptionAttribute) as? String == "Close"
        }) {
            _ = AXUIElementPerformAction(button, kAXPressAction as CFString)
        }
    }
}
