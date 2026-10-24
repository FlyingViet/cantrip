import ImageIO
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Images, videos and files pasted into the message box, handed to the composer's + menu so they
/// go through the same processors, limits and messages as picked attachments.
struct ComposerPasteRequest: Equatable {
    let id = UUID()
    let providers: [NSItemProvider]

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

enum ComposerPasteError: LocalizedError, Equatable {
    case updateMac, chooseBackend, documentsNeedUpdate

    var errorDescription: String? {
        switch self {
        case .updateMac: return "Update Cantrip on your Mac to attach photos and files."
        case .chooseBackend:
            return "Choose a Claude, Copilot, or Codex backend on your Mac to attach photos, videos and files."
        case .documentsNeedUpdate: return "Update Cantrip on your Mac to attach documents other than photos and videos."
        }
    }
}

enum ComposerPaste {
    enum Kind: Equatable { case image, video, file }

    struct Item {
        let provider: NSItemProvider
        let kind: Kind
        let type: UTType
        /// Copied in Finder or Files, so it has a name of its own.
        let copiedAsFile: Bool
    }

    /// Whether a paste attaches instead of inserting text. Copied files always attach (Finder also
    /// puts their names on the clipboard as text). Otherwise any text wins, because a copied cell,
    /// note or web page often carries a picture of itself; photos, videos and documents attach.
    static func attaches(_ items: [[String]]) -> Bool {
        let types = items.joined().compactMap(UTType.init)
        if types.contains(where: { $0.conforms(to: .fileURL) }) { return true }
        if types.contains(where: { $0.conforms(to: .text) }) { return false }
        return types.contains { kind(of: $0) != nil }
    }

    /// Videos are what Cantrip can play (MOV, MP4) and photos what ImageIO can read; anything else
    /// copied as a file is a document, source code and dotfiles included. Data alone must be a
    /// declared document format, so an app's private clipboard formats aren't sent as documents.
    static func kind(of type: UTType, copiedAsFile: Bool = false) -> Kind? {
        if type == .quickTimeMovie || type == .mpeg4Movie { return .video }
        if type.conforms(to: .image), decodableImages.contains(type.identifier) { return .image }
        guard !type.conforms(to: .url) else { return nil }
        // Files with undeclared extensions (main.go, Makefile, .env) only have a dynamic type.
        if copiedAsFile { return type.conforms(to: .data) || type.isDynamic ? .file : nil }
        return type.conforms(to: .data) && !type.isDynamic && type.preferredFilenameExtension != nil ? .file : nil
    }

    private static let decodableImages = Set(CGImageSourceCopyTypeIdentifiers() as? [String] ?? [])

    /// An item's most useful form: a video, else a photo, else a document.
    static func best(_ types: [UTType], copiedAsFile: Bool) -> (kind: Kind, type: UTType)? {
        for wanted in [Kind.video, .image, .file] {
            if let type = types.first(where: { kind(of: $0, copiedAsFile: copiedAsFile) == wanted }) {
                return (wanted, type)
            }
        }
        return nil
    }

    /// The pasted items that can be attached; folders and packages are left out.
    static func classify(_ providers: [NSItemProvider]) -> [Item] {
        providers.compactMap { provider in
            let types = provider.registeredContentTypes
            let copiedAsFile = types.contains { $0.conforms(to: .fileURL) }
            guard let match = best(types, copiedAsFile: copiedAsFile) else { return nil }
            return Item(provider: provider, kind: match.kind, type: match.type, copiedAsFile: copiedAsFile)
        }
    }

    static func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cantrip-paste-\(UUID().uuidString)", isDirectory: true)
    }

    static func loadData(_ item: Item) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = item.provider.loadDataRepresentation(forTypeIdentifier: item.type.identifier) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? ImageAttachmentError.invalidImage) }
            }
        }
    }

    /// Copies the pasted file out of the provider's short-lived location, keeping its name.
    static func copyFile(_ item: Item, into folder: URL) async throws -> URL {
        let originalName = await originalName(of: item.provider), type = item.type, copiedAsFile = item.copiedAsFile
        return try await withCheckedThrowingContinuation { continuation in
            _ = item.provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? FileAttachmentError.invalid)
                    return
                }
                do {
                    let directory = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let name = fileName(originalName ?? url.lastPathComponent, type: type, copiedAsFile: copiedAsFile)
                    let destination = directory.appendingPathComponent(name)
                    try FileManager.default.copyItem(at: url, to: destination)
                    continuation.resume(returning: destination)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// The copied file's own name. The file a provider hands over has a generic one ("PDF document").
    private static func originalName(of provider: NSItemProvider) async -> String? {
        if let name = provider.suggestedName, !name.isEmpty { return name }
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url?.isFileURL == true ? url?.lastPathComponent : nil)
            }
        }
    }

    /// A safe file name. A copied file keeps its own; pasted data without an extension gets its
    /// type's, which video import needs.
    static func fileName(_ suggested: String, type: UTType, copiedAsFile: Bool = false) -> String {
        var name = suggested.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." { name = "Pasted" }
        if !copiedAsFile, (name as NSString).pathExtension.isEmpty, let ext = type.preferredFilenameExtension {
            name += "." + ext
        }
        return name
    }

    #if os(macOS)
    /// Copied files, or copied photos, videos and documents with no text beside them, as
    /// attachments; nil leaves the paste to the text field.
    static func providers(from pasteboard: NSPasteboard) -> [NSItemProvider]? {
        let items = pasteboard.pasteboardItems ?? []
        guard attaches(items.map { $0.types.map(\.rawValue) }) else { return nil }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls.map { NSItemProvider(contentsOf: $0) ?? NSItemProvider() }
        }
        // Each item in its most useful form: a screenshot as a photo, a PDF as a document.
        return items.compactMap { item in
            guard let match = best(item.types.compactMap { UTType($0.rawValue) }, copiedAsFile: false),
                  let data = item.data(forType: NSPasteboard.PasteboardType(match.type.identifier)) else { return nil }
            return NSItemProvider(item: data as NSData, typeIdentifier: match.type.identifier)
        }
    }
    #endif
}

extension View {
    /// Pasting into this text field attaches copied photos, videos and files through `perform`
    /// while `isEnabled`; text still pastes as text. iOS adds Paste to the field's menu for them,
    /// and the Mac takes Command-V.
    func composerPaste(isEnabled: Bool, perform: @escaping ([NSItemProvider]) -> Void) -> some View {
        background(ComposerPasteHook(isEnabled: isEnabled, perform: perform))
    }
}

#if os(iOS)
/// SwiftUI's text field offers Paste only for text, URLs and (in rich text) images. This finds the
/// UITextView behind the field it decorates and gives that one view a subclass that also offers
/// Paste for photos, videos and files and hands them over. A paste from the menu or keyboard is
/// the person's choice, so reading the clipboard then doesn't show iOS's paste prompt.
private struct ComposerPasteHook: UIViewRepresentable {
    let isEnabled: Bool
    let perform: ([NSItemProvider]) -> Void

    func makeUIView(context: Context) -> HookView { HookView() }

    func updateUIView(_ view: HookView, context: Context) {
        view.handler = isEnabled ? perform : nil
        view.install()
    }

    static func dismantleUIView(_ view: HookView, coordinator: ()) {
        view.handler = nil
    }

    final class HookView: UIView {
        var handler: (([NSItemProvider]) -> Void)? {
            didSet { if let textView { ComposerPasteTextViews.set(handler, for: textView) } }
        }
        private weak var textView: UITextView?

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            install()
        }

        /// Waits a turn so the field's own view is in the window.
        func install() {
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }

        private func attach() {
            guard let window else { return }
            if let textView, textView.window === window { return }
            let frame = convert(bounds, to: window)
            var ancestor = superview
            for _ in 0..<6 {
                guard let view = ancestor else { break }
                if let found = Self.textViews(in: view).first(where: {
                    $0.convert($0.bounds, to: window).intersects(frame)
                }) {
                    textView = found
                    ComposerPasteTextViews.set(handler, for: found)
                    ComposerPasteTextViews.install(on: found)
                    return
                }
                ancestor = view.superview
            }
        }

        private static func textViews(in view: UIView) -> [UITextView] {
            view.subviews.flatMap { subview -> [UITextView] in
                if let textView = subview as? UITextView { return [textView] }
                return textViews(in: subview)
            }
        }
    }
}

private final class ComposerPasteHandler {
    let perform: ([NSItemProvider]) -> Void
    init(_ perform: @escaping ([NSItemProvider]) -> Void) { self.perform = perform }
}

private enum ComposerPasteTextViews {
    private static let handlers = NSMapTable<UITextView, ComposerPasteHandler>.weakToStrongObjects()
    private static let suffix = "_CantripComposerPaste"

    static func set(_ perform: (([NSItemProvider]) -> Void)?, for textView: UITextView) {
        if let perform { handlers.setObject(ComposerPasteHandler(perform), forKey: textView) }
        else { handlers.removeObject(forKey: textView) }
    }

    /// Something to attach, judged from the clipboard's types alone (no paste prompt).
    static func handler(for textView: UITextView) -> ComposerPasteHandler? {
        guard let handler = handlers.object(forKey: textView),
              ComposerPaste.attaches(UIPasteboard.general.types(forItemSet: nil) ?? []) else { return nil }
        return handler
    }

    static func install(on textView: UITextView) {
        guard let base = object_getClass(textView) else { return }
        let baseName = NSStringFromClass(base)
        guard !baseName.hasSuffix(suffix) else { return }
        let name = baseName + suffix
        if let existing = NSClassFromString(name) {
            object_setClass(textView, existing)
            return
        }
        guard let subclass = objc_allocateClassPair(base, name, 0) else { return }

        let pasteAction = #selector(UIResponderStandardEditActions.paste(_:))
        let canPerform = #selector(UIResponder.canPerformAction(_:withSender:))
        typealias CanPerform = @convention(c) (AnyObject, Selector, Selector, AnyObject?) -> Bool
        let superCanPerform = unsafeBitCast(class_getMethodImplementation(base, canPerform), to: CanPerform.self)
        let canPerformBlock: @convention(block) (UITextView, Selector, AnyObject?) -> Bool = { view, action, sender in
            if action == pasteAction, handler(for: view) != nil { return true }
            return superCanPerform(view, canPerform, action, sender)
        }
        typealias Paste = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        let superPaste = unsafeBitCast(class_getMethodImplementation(base, pasteAction), to: Paste.self)
        let pasteBlock: @convention(block) (UITextView, AnyObject?) -> Void = { view, sender in
            if let handler = handler(for: view) {
                handler.perform(UIPasteboard.general.itemProviders)
            } else {
                superPaste(view, pasteAction, sender)
            }
        }
        // Reports the original class, as KVO's subclasses do.
        let classBlock: @convention(block) (AnyObject) -> AnyClass = { _ in base }

        for (selector, block) in [(canPerform, canPerformBlock as Any), (pasteAction, pasteBlock as Any),
                                  (NSSelectorFromString("class"), classBlock as Any)] {
            guard let method = class_getInstanceMethod(base, selector) else { continue }
            class_addMethod(subclass, selector, imp_implementationWithBlock(block), method_getTypeEncoding(method))
        }
        objc_registerClassPair(subclass)
        object_setClass(textView, subclass)
    }
}

#elseif os(macOS)
/// Command-V in the decorated field with copied files or an image (and no text) attaches them;
/// anything else reaches the field as usual.
private struct ComposerPasteHook: NSViewRepresentable {
    let isEnabled: Bool
    let perform: ([NSItemProvider]) -> Void

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.perform = isEnabled ? perform : nil
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.perform = nil
    }

    final class MonitorView: NSView {
        var perform: (([NSItemProvider]) -> Void)? {
            didSet { updateMonitor() }
        }
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateMonitor()
        }

        private func updateMonitor() {
            let active = perform != nil && window != nil
            if active, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    self?.handle(event) == true ? nil : event
                }
            } else if !active, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard let perform, let window, event.window === window,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    .subtracting([.capsLock, .numericPad, .function]) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "v",
                  let editor = window.firstResponder as? NSTextView, !editor.hasMarkedText(),
                  editor.convert(editor.bounds, to: nil).intersects(convert(bounds, to: nil)),
                  let providers = ComposerPaste.providers(from: .general), !providers.isEmpty else { return false }
            perform(providers)
            return true
        }
    }
}
#endif
