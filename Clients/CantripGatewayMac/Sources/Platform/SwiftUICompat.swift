import AppKit
import SwiftUI

// iOS-only SwiftUI modifiers used by the shared Hermes views, mapped to their macOS
// equivalents or to no-ops where macOS has no such concept.

enum CompatTitleDisplayMode { case automatic, inline, large }
enum CompatAutocapitalization { case never, words, sentences, characters }
enum UIKeyboardType { case `default`, asciiCapable, numberPad, decimalPad, URL, emailAddress, phonePad, numbersAndPunctuation, webSearch }
enum UITextContentType { case oneTimeCode, password, username, URL, emailAddress, newPassword }

extension View {
    func navigationBarTitleDisplayMode(_ mode: CompatTitleDisplayMode) -> some View { self }
    func textInputAutocapitalization(_ autocapitalization: CompatAutocapitalization?) -> some View { self }
    func keyboardType(_ type: UIKeyboardType) -> some View { self }
    func navigationBarBackButtonHidden(_ hidden: Bool = true) -> some View { self }
    func statusBarHidden(_ hidden: Bool = true) -> some View { self }
    func persistentSystemOverlays(_ visibility: Visibility) -> some View { self }

    func fullScreenCover<Content: View>(
        isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss, content: content)
    }

    func fullScreenCover<Item: Identifiable, Content: View>(
        item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        sheet(item: item, onDismiss: onDismiss, content: content)
    }
}

extension ToolbarItemPlacement {
    static var topBarLeading: ToolbarItemPlacement { .navigation }
    static var topBarTrailing: ToolbarItemPlacement { .primaryAction }
    static var bottomBar: ToolbarItemPlacement { .automatic }
    static var navigationBarLeading: ToolbarItemPlacement { .navigation }
    static var navigationBarTrailing: ToolbarItemPlacement { .primaryAction }
}

extension ToolbarPlacement {
    static var navigationBar: ToolbarPlacement { .windowToolbar }
    static var bottomBar: ToolbarPlacement { .windowToolbar }
    static var tabBar: ToolbarPlacement { .windowToolbar }
}

extension TabBarMinimizeBehavior {
    static var never: TabBarMinimizeBehavior { .automatic }
}

extension ListStyle where Self == InsetListStyle {
    static var insetGrouped: InsetListStyle { InsetListStyle() }
}

/// macOS lists have no edit mode; reordering works by dragging.
struct EditButton: View {
    var body: some View { EmptyView() }
}

/// Lets the shared UIKit-style representables (e.g. the MCP App web view) host AppKit views.
protocol UIViewRepresentable: NSViewRepresentable {
    associatedtype UIViewType: NSView
    @MainActor func makeUIView(context: Context) -> UIViewType
    @MainActor func updateUIView(_ uiView: UIViewType, context: Context)
    @MainActor static func dismantleUIView(_ uiView: UIViewType, coordinator: Coordinator)
}

@MainActor
extension UIViewRepresentable {
    func makeNSView(context: Context) -> UIViewType { makeUIView(context: context) }
    func updateNSView(_ nsView: UIViewType, context: Context) { updateUIView(nsView, context: context) }
    static func dismantleNSView(_ nsView: UIViewType, coordinator: Coordinator) {
        dismantleUIView(nsView, coordinator: coordinator)
    }
    static func dismantleUIView(_ uiView: UIViewType, coordinator: Coordinator) {}
}

/// macOS lists have no edit mode; shared lists that set it compile against this inert value.
enum EditMode { case inactive, transient, active }

private struct EditModeKey: EnvironmentKey {
    static let defaultValue: Binding<EditMode>? = nil
}

extension EnvironmentValues {
    var editMode: Binding<EditMode>? {
        get { self[EditModeKey.self] }
        set { self[EditModeKey.self] = newValue }
    }
}
