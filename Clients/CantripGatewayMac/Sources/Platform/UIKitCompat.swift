import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The shared Hermes (iOS) sources compile unchanged on macOS by resolving the UIKit names
// they use to AppKit equivalents. Only names the shared code needs live here.

typealias UIImage = NSImage
typealias UIColor = NSColor
typealias UIFont = NSFont

extension NSImage {
    convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: .zero)
    }

    convenience init?(systemName: String) {
        self.init(systemSymbolName: systemName, accessibilityDescription: nil)
    }

    var cgImage: CGImage? {
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    var scale: CGFloat { 1 }

    func jpegData(compressionQuality: CGFloat) -> Data? {
        bitmap?.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }

    func pngData() -> Data? {
        bitmap?.representation(using: .png, properties: [:])
    }

    private var bitmap: NSBitmapImageRep? {
        guard let cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cgImage)
    }
}

extension Image {
    init(uiImage: NSImage) {
        self.init(nsImage: uiImage)
    }
}

enum UIUserInterfaceStyle {
    case unspecified, light, dark
}

enum UIAccessibilityContrast { case unspecified, normal, high }

struct UITraitCollection {
    var userInterfaceStyle: UIUserInterfaceStyle
    var accessibilityContrast: UIAccessibilityContrast = .normal

    init(userInterfaceStyle: UIUserInterfaceStyle, accessibilityContrast: UIAccessibilityContrast = .normal) {
        self.userInterfaceStyle = userInterfaceStyle
        self.accessibilityContrast = accessibilityContrast
    }

    init(appearance: NSAppearance,
         increaseContrast: Bool = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast) {
        // High-contrast names first: bestMatch prefers earlier names when several apply.
        let match = appearance.bestMatch(from: [
            .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua, .darkAqua, .aqua,
        ])
        let dark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
        let high = increaseContrast
            || match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
        userInterfaceStyle = dark ? .dark : .light
        accessibilityContrast = high ? .high : .normal
    }
}

extension NSColor {
    convenience init(dynamicProvider: @escaping (UITraitCollection) -> NSColor) {
        self.init(name: nil) { appearance in
            dynamicProvider(UITraitCollection(appearance: appearance))
        }
    }

    static var systemBackground: NSColor { .windowBackgroundColor }
    static var secondarySystemBackground: NSColor { .controlBackgroundColor }
    static var tertiarySystemBackground: NSColor { .underPageBackgroundColor }
    static var systemGroupedBackground: NSColor { .windowBackgroundColor }
    static var secondarySystemGroupedBackground: NSColor { .controlBackgroundColor }
    static var label: NSColor { .labelColor }
    static var secondaryLabel: NSColor { .secondaryLabelColor }
    static var tertiaryLabel: NSColor { .tertiaryLabelColor }
    static var separator: NSColor { .separatorColor }
    static var systemGray2: NSColor { .systemGray }
    static var systemGray3: NSColor { .systemGray }
    static var systemGray4: NSColor { .systemGray }
    static var systemGray5: NSColor { .quaternaryLabelColor }
    static var systemGray6: NSColor { .controlBackgroundColor }
}

extension Color {
    init(uiColor: NSColor) {
        self.init(nsColor: uiColor)
    }
}

final class UIPasteboard {
    static let general = UIPasteboard()

    var string: String? {
        get { NSPasteboard.general.string(forType: .string) }
        set {
            NSPasteboard.general.clearContents()
            if let newValue { NSPasteboard.general.setString(newValue, forType: .string) }
        }
    }

    var image: NSImage? {
        get { NSImage(pasteboard: NSPasteboard.general) }
        set {
            NSPasteboard.general.clearContents()
            if let newValue { NSPasteboard.general.writeObjects([newValue]) }
        }
    }

    var hasStrings: Bool { string != nil }
    var hasImages: Bool { NSImage.canInit(with: NSPasteboard.general) }
}

/// Just enough application state for the shared biometric and lifecycle code.
@MainActor
final class UIApplication {
    enum State { case active, inactive, background }

    static let shared = UIApplication()
    static let didBecomeActiveNotification = NSApplication.didBecomeActiveNotification
    static let willResignActiveNotification = NSApplication.willResignActiveNotification
    static let didEnterBackgroundNotification = NSApplication.didHideNotification
    static let willEnterForegroundNotification = NSApplication.willUnhideNotification
    static let openSettingsURLString = "x-apple.systempreferences:"
    static let openNotificationSettingsURLString =
        "x-apple.systempreferences:com.apple.Notifications-Settings.extension"

    var applicationState: State {
        if NSApp.isHidden { return .background }
        return NSApp.isActive ? .active : .inactive
    }

    func open(_ url: URL, options: [String: Any] = [:], completionHandler: ((Bool) -> Void)? = nil) {
        completionHandler?(NSWorkspace.shared.open(url))
    }

    func canOpenURL(_ url: URL) -> Bool {
        NSWorkspace.shared.urlForApplication(toOpen: url) != nil
    }

    func registerForRemoteNotifications() {
        NSApp.registerForRemoteNotifications()
    }
}

enum UIAccessibility {
    struct Notification {
        static let screenChanged = Notification()
        static let announcement = Notification()
    }

    static var isReduceMotionEnabled: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var isVoiceOverRunning: Bool { NSWorkspace.shared.isVoiceOverEnabled }
    static var isReduceTransparencyEnabled: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    @MainActor
    static func post(notification: Notification, argument: Any?) {
        guard let text = argument as? String else { return }
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }
}

enum UIUserInterfaceIdiom { case unspecified, phone, pad, mac }

@MainActor
final class UIDevice {
    static let current = UIDevice()
    var userInterfaceIdiom: UIUserInterfaceIdiom { .mac }
    var name: String { Host.current().localizedName ?? "Mac" }
    var systemName: String { "macOS" }
    var systemVersion: String { ProcessInfo.processInfo.operatingSystemVersionString }
}

/// iOS-only jetsam headroom query; macOS has no per-process limit, so report "unknown".
func os_proc_available_memory() -> Int { 0 }

extension NSView {
    var traitCollection: UITraitCollection { UITraitCollection(appearance: effectiveAppearance) }
}
